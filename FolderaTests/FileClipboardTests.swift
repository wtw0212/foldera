import AppKit
import Testing
@testable import Foldera

@MainActor
struct FileClipboardTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("FolderaClipboardTests-\(UUID())"))
    private var a: URL { URL(fileURLWithPath: "/tmp/foldera-cut-a") }
    private var b: URL { URL(fileURLWithPath: "/tmp/foldera-cut-b") }

    private var pastedURLs: [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    @Test func partialMovePreservesOnlyRemainingCutItems() {
        defer { pasteboard.clearContents() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.cut([a, b])
        let count = pasteboard.changeCount
        clipboard.finishMove(TransferResult(moved: [(a, URL(fileURLWithPath: "/tmp/moved-a"))]), urls: [a, b], changeCount: count)
        #expect(!clipboard.isCut(a) && clipboard.isCut(b))
        #expect(clipboard.cutURLs == [b] && pastedURLs == [b])
    }

    @Test func committedCopyConsumesItsCutSourceWhileUnstartedItemsStayCut() {
        defer { pasteboard.clearContents() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.cut([a, b])
        let result = TransferResult(consumedCutSources: [a], error: RemoteError.failed("cleanup"))
        clipboard.finishMove(result, urls: [a, b], changeCount: pasteboard.changeCount)
        #expect(result.completedSources.isEmpty)
        #expect(!clipboard.isCut(a) && clipboard.isCut(b))
        #expect(clipboard.cutURLs == [b] && pastedURLs == [b])
    }

    @Test func cancelledOrNoOpMovePreservesCutItems() {
        defer { pasteboard.clearContents() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.cut([a, b])
        clipboard.finishMove(TransferResult(error: CopyEngine.Cancelled()), urls: [a, b], changeCount: pasteboard.changeCount)
        #expect(clipboard.isCut(a) && clipboard.isCut(b))
        #expect(pastedURLs == [a, b])
        clipboard.finishMove(TransferResult(), urls: [a, b], changeCount: pasteboard.changeCount)
        #expect(clipboard.isCut(a) && clipboard.isCut(b) && clipboard.canPaste)
    }

    @Test func completedMoveClearsCutItems() {
        defer { pasteboard.clearContents() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.cut([a])
        clipboard.finishMove(TransferResult(moved: [(a, b)]), urls: [a], changeCount: pasteboard.changeCount)
        #expect(clipboard.cutURLs.isEmpty && !clipboard.canPaste)
    }

    @Test func transferCompletionDoesNotClearNewerClipboard() {
        defer { pasteboard.clearContents() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.cut([a])
        let count = pasteboard.changeCount
        clipboard.copy([b])
        clipboard.finishMove(TransferResult(moved: [(a, b)]), urls: [a], changeCount: count)
        #expect(clipboard.cutURLs.isEmpty && pastedURLs == [b])
    }
}
