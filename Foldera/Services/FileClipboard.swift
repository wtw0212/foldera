import AppKit
import Observation

/// Cut / copy / paste of files through the general pasteboard.
/// Copy is interoperable with Finder; "cut" is remembered locally and turns the next paste into a move.
@Observable
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var cutURLs: Set<URL> = []
    @ObservationIgnored private var cutChangeCount: Int?
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func copy(_ urls: [URL]) {
        write(urls)
        cutURLs = []
        cutChangeCount = nil
    }

    func cut(_ urls: [URL]) {
        write(urls)
        cutURLs = Set(urls.map(\.normalizedFileURL))
        cutChangeCount = pasteboard.changeCount
    }

    /// True while `url` is waiting to be moved by a paste (shown dimmed, like Explorer).
    func isCut(_ url: URL) -> Bool {
        cutURLs.contains(url.normalizedFileURL) && cutChangeCount == pasteboard.changeCount
    }

    var canPaste: Bool {
        ItemPasteboard.hasItems(pasteboard)
    }

    /// Pastes into `directory`: a move after Cut, otherwise a copy. Returns what changed.
    func paste(into directory: URL) async -> TransferResult {
        let urls = ItemPasteboard.urls(from: pasteboard)
        guard !urls.isEmpty else { return TransferResult() }
        if cutChangeCount == pasteboard.changeCount {
            let changeCount = pasteboard.changeCount
            let result = await FileTransfers.shared.run(.move, urls, into: directory)
            FileUndo.shared.record(FileChange(result, kind: .move), name: "Move")
            finishMove(result, urls: urls, changeCount: changeCount)
            return result
        }
        let result = await FileTransfers.shared.run(.copy, urls, into: directory)
        FileUndo.shared.record(FileChange(result, kind: .copy), name: "Copy")
        return result
    }

    /// Do not clear a newer clipboard while a transfer was awaiting its worker.
    func finishMove(_ result: TransferResult, urls: [URL], changeCount: Int) {
        guard cutChangeCount == changeCount, pasteboard.changeCount == changeCount else { return }
        let moved = Set((result.moved.map(\.from) + result.completedSources + result.consumedCutSources).map(\.normalizedFileURL))
        let remaining = urls.filter { !moved.contains($0.normalizedFileURL) }
        if remaining.isEmpty {
            cutURLs = []
            cutChangeCount = nil
            pasteboard.clearContents()
        } else {
            cut(remaining)
        }
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map(ItemPasteboard.writer))
    }
}
