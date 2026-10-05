import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// An sftp:// item. Kept private to Foldera so Finder doesn't turn dropped server items into .webloc files.
    static let remoteItemURL = NSPasteboard.PasteboardType(UTType.remoteItem.identifier)
    /// An item inside an archive, for drops within Foldera; other apps get a file promise instead.
    nonisolated static let archiveItemURL = NSPasteboard.PasteboardType("com.wtw0212.foldera.archive-item-url")
}

extension UTType {
    /// Declared in Config/Foldera-Info.plist.
    static let remoteItem = UTType(importedAs: "com.wtw0212.foldera.remote-url")
}

/// Puts local files and server items on pasteboards (drag and drop, copy and paste) and reads them back.
enum ItemPasteboard {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .remoteItemURL, .archiveItemURL]

    static func writer(for url: URL) -> any NSPasteboardWriting {
        if url.isInArchive { return ArchiveItemPromise(itemURL: url) }
        guard url.isRemote else { return url as NSURL }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .remoteItemURL)
        return item
    }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            if let archived = item.string(forType: .archiveItemURL), let url = URL(string: archived), url.isInArchive {
                return url
            }
            if let remote = item.string(forType: .remoteItemURL), let url = URL(string: remote), url.isRemote {
                return url
            }
            if let file = item.string(forType: .fileURL), let url = URL(string: file), url.isFileURL {
                return url
            }
            return nil
        }
    }

    static func hasItems(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: types) != nil
    }
}

/// Dragging an item out of an archive: Finder and other apps get a file promise, kept by extracting the
/// item where they drop it; Foldera's own folders read the item's address and extract it themselves.
nonisolated final class ArchiveItemPromise: NSFilePromiseProvider {
    let itemURL: URL

    init(itemURL: URL) {
        self.itemURL = itemURL
        super.init()
        let location = itemURL.archiveLocation
        let entry = location.flatMap { ArchiveCatalog.shared.entry($0.path, in: $0.archive) }
        fileType = entry?.isDirectory == true ? UTType.folder.identifier
            : UTType(filenameExtension: ((location?.name ?? "") as NSString).pathExtension)?.identifier ?? UTType.data.identifier
        delegate = ArchivePromises.shared
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.archiveItemURL]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .archiveItemURL ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .archiveItemURL ? itemURL.absoluteString : super.pasteboardPropertyList(forType: type)
    }
}

/// Keeps archive file promises: extracts the item next to where the other app wants it, with progress.
nonisolated final class ArchivePromises: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = ArchivePromises()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider as? ArchiveItemPromise)?.itemURL.archiveLocation?.name ?? "Item"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let done = completionHandler
        guard let location = (filePromiseProvider as? ArchiveItemPromise)?.itemURL.archiveLocation else {
            return done(CocoaError(.fileNoSuchFile))
        }
        Task { @MainActor in
            do {
                guard let created = try await ArchiveExtraction.items([location], from: location.archive,
                                                                      into: url.deletingLastPathComponent())?.first else {
                    return done(CocoaError(.userCancelled))
                }
                // The other app names the destination; the extraction may have had to pick another free name.
                if created != url, !FileOperations.exists(url) { try FileManager.default.moveItem(at: created, to: url) }
                done(nil)
            } catch {
                done(error)
            }
        }
    }
}
