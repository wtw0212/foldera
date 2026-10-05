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

    @Test func openingATarGzExtractsItIntoAFolderNamedAfterIt() async throws {
        let directory = try TestDirectory()
        _ = try directory.file("note.txt", contents: "archive payload")
        let archive = directory.path("note.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", directory.url.path, "note.txt"]
        try tar.run()
        tar.waitUntilExit()
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [archive]
        tab.openSelection()
        // tar.gz can't be browsed (7-Zip would only show the .tar inside), so it's extracted like before.
        try await eventually(timeout: .seconds(10)) { tab.selection.first?.lastPathComponent == "note" && !tab.isLoading }
        let folder = try #require(tab.selection.first)
        #expect(try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8) == "archive payload")
        #expect(!tab.isInsideArchive)
    }

    @Test func openingAnArchiveBrowsesItReadOnlyAndUpLeavesIt() async throws {
        let savedOpener = ArchiveWindows.opener
        ArchiveWindows.opener = nil
        defer { ArchiveWindows.opener = savedOpener }
        let directory = try TestDirectory()
        let folder = try directory.folder("Notes")
        try "first".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Deep"), withIntermediateDirectories: false)
        try "second".write(to: folder.appendingPathComponent("Deep/b*?.txt"), atomically: true, encoding: .utf8)
        let archive = try Archives.compress([folder], format: .sevenZip, fallbackFolder: directory.url)
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [archive]
        tab.openSelection()
        try await eventually(timeout: .seconds(10)) { tab.isInsideArchive && tab.items.map(\.name) == ["Notes"] }
        #expect(tab.title == L10n.format("%@ (archive)", "Notes.7z") && !tab.acceptsItems && !tab.canCompressSelection)
        #expect(Breadcrumbs.segments(for: tab.url).suffix(2).map(BrowserTab.pathName) == [directory.url.lastPathComponent, "Notes.7z"])

        tab.selection = [tab.items[0].url]
        tab.openSelection()
        try await eventually(timeout: .seconds(10)) { Set(tab.items.map(\.name)) == ["a.txt", "Deep"] }
        let file = try #require(tab.items.first { $0.name == "a.txt" })
        #expect(file.size == 5 && !file.isDirectory)
        #expect(BrowserTab.editableAddress(of: tab.url) == archive.path + "/Notes")

        // Copy takes items out to a temporary folder, so they paste anywhere.
        let extracted = try ArchiveDirectory.extractToTemporaryFolder(tab.items.map(\.url))
        #expect(Set(extracted.map(\.lastPathComponent)) == ["a.txt", "Deep"])
        #expect(try String(contentsOf: try #require(extracted.first { $0.lastPathComponent == "Deep" }).appendingPathComponent("b*?.txt"), encoding: .utf8) == "second")

        // Extract to a folder keeps both copies when names clash and shows the result.
        let target = try directory.folder("target")
        try "existing".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        tab.extract([try #require(file.url.archiveLocation)], from: archive, into: target)
        try await eventually(timeout: .seconds(10)) { tab.url == target.normalizedFileURL && tab.selection.first?.lastPathComponent == "a (2).txt" }
        #expect(try String(contentsOf: target.appendingPathComponent("a (2).txt"), encoding: .utf8) == "first")

        tab.goBack()
        try await eventually(timeout: .seconds(10)) { tab.isInsideArchive && !tab.isLoading }
        tab.goUp()
        try await eventually(timeout: .seconds(10)) { tab.url.archiveLocation?.isRoot == true && !tab.isLoading }
        tab.goUp()
        try await eventually(timeout: .seconds(10)) { tab.url == directory.url.normalizedFileURL && tab.selection == [archive] }
    }

    @Test func archivesWithEncryptedNamesAskForThePasswordBeforeListing() async throws {
        let savedOpener = ArchiveWindows.opener
        ArchiveWindows.opener = nil
        defer { ArchiveWindows.opener = savedOpener }
        let directory = try TestDirectory()
        let file = try directory.file("secret.txt", contents: "hidden")
        let archive = directory.path("locked.7z")
        let phrase = UUID().uuidString
        var options = Archives.Options(format: .sevenZip)
        options.password = phrase
        try Archives.compress([file], options: options, to: archive)
        var asked: [Bool] = []
        BrowserTab.passwordPrompt = { _, wasWrong in
            asked.append(wasWrong)
            return asked.count == 1 ? "wrong" : phrase
        }
        defer { BrowserTab.passwordPrompt = nil; ArchiveCatalog.shared.setPassword(nil, for: archive) }
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [archive]
        tab.openSelection()
        try await eventually(timeout: .seconds(10)) { tab.isInsideArchive && tab.items.map(\.name) == ["secret.txt"] }
        #expect(asked == [false, true])
        let copies = try ArchiveDirectory.extractToTemporaryFolder(tab.items.map(\.url))
        #expect(try String(contentsOf: copies[0], encoding: .utf8) == "hidden")
    }

    @Test func archivesOpenInTheirOwnWindowAfterThePasswordIsKnown() async throws {
        let directory = try TestDirectory()
        let file = try directory.file("secret.txt", contents: "hidden")
        let archive = directory.path("locked.7z")
        var options = Archives.Options(format: .sevenZip)
        options.password = UUID().uuidString
        try Archives.compress([file], options: options, to: archive)
        var opened: [URL] = []
        var prompts = 0
        let savedOpener = ArchiveWindows.opener
        ArchiveWindows.opener = { opened.append($0) }
        BrowserTab.passwordPrompt = { _, _ in prompts += 1; return nil }
        defer { BrowserTab.passwordPrompt = nil; ArchiveWindows.opener = savedOpener }
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [archive]

        // Cancelling the password opens nothing and leaves this window where it was.
        tab.openSelection()
        try await eventually(timeout: .seconds(10)) { prompts == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(opened.isEmpty && tab.url == directory.url.normalizedFileURL)

        BrowserTab.passwordPrompt = { _, _ in options.password }
        tab.openSelection()
        try await eventually(timeout: .seconds(10)) { opened == [ArchiveLocation(archive: archive).url] }
        #expect(tab.url == directory.url.normalizedFileURL)
        ArchiveCatalog.shared.setPassword(nil, for: archive)
    }

    @Test func extractingToAChosenFolderOpensItAndSelectsTheResult() async throws {
        let directory = try TestDirectory()
        let original = try directory.file("note.txt", contents: "archive payload")
        let target = try directory.folder("chosen")
        let archive = try Archives.compress([original], fallbackFolder: directory.url)
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [archive]
        tab.extractSelection(.folder(target, ownFolder: true))
        let folder = target.appendingPathComponent("note.txt").normalizedFileURL
        try await eventually(timeout: .seconds(10)) { tab.url == target.normalizedFileURL && tab.selection == [folder] && !tab.isLoading }
        #expect(try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8) == "archive payload")
        #expect(tab.canGoBack, "Back returns to the archive's folder")

        tab.goBack()
        try await eventually { tab.url == directory.url.normalizedFileURL && !tab.isLoading }
        tab.selection = [archive]
        tab.extractSelection(.folder(target, ownFolder: false))
        // "note.txt" there is now the first extraction's folder, so the file keeps both.
        try await eventually(timeout: .seconds(10)) { tab.url == target.normalizedFileURL && tab.selection.first?.lastPathComponent == "note (2).txt" && !tab.isLoading }
        #expect(try String(contentsOf: target.appendingPathComponent("note (2).txt"), encoding: .utf8) == "archive payload")
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
