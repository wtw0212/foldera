import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// An sftp:// item. Kept private to Foldera so Finder doesn't turn dropped server items into .webloc files.
    static let remoteItemURL = NSPasteboard.PasteboardType(UTType.remoteItem.identifier)
}

extension UTType {
    /// Declared in Config/Foldera-Info.plist.
    static let remoteItem = UTType(importedAs: "com.wtw0212.foldera.remote-url")
}

/// Puts local files and server items on pasteboards (drag and drop, copy and paste) and reads them back.
enum ItemPasteboard {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .remoteItemURL]

    static func writer(for url: URL) -> any NSPasteboardWriting {
        guard url.isRemote else { return url as NSURL }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .remoteItemURL)
        return item
    }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
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
