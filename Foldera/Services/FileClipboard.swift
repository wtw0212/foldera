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

    /// Pastes into `directory` and returns the URLs of the pasted items.
    func paste(into directory: URL) async throws -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        if cutChangeCount == pasteboard.changeCount {
            let moved = try await FileOperations.move(urls, into: directory)
            cutURLs = []
            cutChangeCount = nil
            pasteboard.clearContents()
            return moved
        }
        return try await FileOperations.copy(urls, into: directory)
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }
}
