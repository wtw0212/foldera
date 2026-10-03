import AppKit
import Quartz
import Testing
@testable import Foldera

@Suite(.serialized)
@MainActor
struct BrowserArchiveTests {
    @Test func compressAndExtractCommandsSelectTheCreatedItemsAndKeepOriginalFiles() async throws {
        let directory = try TestDirectory()
        let original = try directory.file("note.txt", contents: "archive payload")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [original]
        tab.compressSelection(.zip)
        let archive = directory.path("note.txt.zip")
        try await eventually(timeout: .seconds(10)) { tab.selection == [archive] && !tab.isLoading }
        #expect(FileOperations.exists(original) && tab.selectedArchives == [archive])
        tab.extractSelection(.ownFolder)
        let extracted = directory.path("note.txt")
        // The existing text file is kept; extraction chooses a fresh folder name.
        try await eventually(timeout: .seconds(10)) { tab.selection.first?.lastPathComponent == "note (2).txt" && !tab.isLoading }
        let folder = try #require(tab.selection.first)
        #expect(try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8) == "archive payload")
        #expect(try String(contentsOf: extracted, encoding: .utf8) == "archive payload")
        tab.selection = [archive]
        tab.extractSelection(.here)
        try await eventually(timeout: .seconds(10)) { tab.selection.first?.lastPathComponent == "note (3).txt" && !tab.isLoading }
        #expect(try String(contentsOf: try #require(tab.selection.first), encoding: .utf8) == "archive payload")
    }

    @Test func clipboardCopiesThenMovesRealFilesWithASeparatePasteboard() async throws {
        let directory = try TestDirectory()
        let copyTarget = try directory.folder("copied"), moveTarget = try directory.folder("moved")
        let source = try directory.file("note.txt", contents: "clipboard payload")
        let pasteboard = NSPasteboard(name: .init("FolderaCopyMoveTests-\(UUID())"))
        defer { pasteboard.clearContents() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        #expect(!clipboard.canPaste)
        #expect(await clipboard.paste(into: copyTarget).results.isEmpty)
        clipboard.copy([source])
        #expect(clipboard.canPaste && !clipboard.isCut(source))
        let copied = await clipboard.paste(into: copyTarget)
        #expect(copied.error == nil && copied.created.count == 1 && FileOperations.exists(source))
        #expect(try String(contentsOf: copyTarget.appendingPathComponent("note.txt"), encoding: .utf8) == "clipboard payload")
        clipboard.cut([source])
        let moved = await clipboard.paste(into: moveTarget)
        #expect(moved.error == nil && moved.moved.count == 1 && !FileOperations.exists(source))
        #expect(clipboard.cutURLs.isEmpty && !clipboard.canPaste)
        #expect(try String(contentsOf: moveTarget.appendingPathComponent("note.txt"), encoding: .utf8) == "clipboard payload")
    }

    @Test func quickLookDataSourceReflectsSelectionAndRejectsOutOfRangeIndices() {
        let look = QuickLook()
        let urls = [URL(fileURLWithPath: "/tmp/one.txt"), URL(fileURLWithPath: "/tmp/two.txt")]
        look.toggle { [] }
        #expect(look.numberOfPreviewItems(in: nil) == 0)
        look.urls = { urls }
        #expect(look.numberOfPreviewItems(in: nil) == 2)
        #expect(look.previewPanel(nil, previewItemAt: 1) as? NSURL == urls[1] as NSURL)
        #expect(look.previewPanel(nil, previewItemAt: 2) == nil)
        look.selectionChanged()
    }
}
