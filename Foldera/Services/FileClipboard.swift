import AppKit
import Observation

/// Cut / copy / paste of files through the general pasteboard.
/// Copy is interoperable with Finder; "cut" is remembered locally and turns the next paste into a move.
@Observable
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var cutURLs: Set<URL> = []
    @ObservationIgnored private var cutChangeCount: Int?
    private let pasteboard = NSPasteboard.general

    private init() {}

    func copy(_ urls: [URL]) {
        write(urls)
        cutURLs = []
        cutChangeCount = nil
    }

    func cut(_ urls: [URL]) {
        write(urls)
        cutURLs = Set(urls)
        cutChangeCount = pasteboard.changeCount
    }

    /// True while `url` is waiting to be moved by a paste (shown dimmed, like Explorer).
    func isCut(_ url: URL) -> Bool {
        cutURLs.contains(url) && cutChangeCount == pasteboard.changeCount
    }

    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Pastes into `directory`: a move after Cut, otherwise a copy. Returns what changed.
    func paste(into directory: URL) async -> TransferResult {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return TransferResult() }
        if cutChangeCount == pasteboard.changeCount {
            let result = await FileTransfers.shared.run(.move, urls, into: directory)
            cutURLs = []
            cutChangeCount = nil
            pasteboard.clearContents()
            return result
        }
        return await FileTransfers.shared.run(.copy, urls, into: directory)
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }
}
