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
        let errors = ErrorCollector()
        defer { #expect(errors.messages.isEmpty) }
        let directory = try TestDirectory()
        _ = try directory.file("note.txt", contents: "archive payload")
        let archive = directory.path("note.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", directory.url.path, "note.txt"]
        try tar.run()
        tar.waitUntilExit()
        try #require(tar.terminationStatus == 0)
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [archive]
        try #require(tab.selectedItems.map(\.url) == [archive])
        tab.openSelection()
        // tar.gz can't be browsed (7-Zip would only show the .tar inside), so it's extracted like before.
        try await eventually(timeout: .seconds(10)) { tab.selection == [directory.path("note")] && !tab.isLoading }
        let folder = try #require(tab.selection.first)
        #expect(try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8) == "archive payload")
        #expect(!tab.isInsideArchive)
    }

    @Test func archiveCompletionReplacesSelectionFromAnInFlightReload() async throws {
        let directory = try TestDirectory()
        let archive = try directory.file("notes.zip")
        let folder = try directory.folder("notes")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [archive]
        tab.reload() // A directory watcher can still be reloading the old selection when extraction finishes.
        try #require(tab.isLoading)
        tab.finishArchiveJob(name: "Extract", created: [folder], error: nil)
        try await eventually { !tab.isLoading }
        #expect(tab.selection == [folder])
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
        tab.extract([try #require(file.url.archiveLocation)], from: archive, into: target, opens: true)
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
        // The new folder named after the archive opens itself.
        let folder = target.appendingPathComponent("note.txt").normalizedFileURL
        try await eventually(timeout: .seconds(10)) { tab.url == folder && !tab.isLoading }
        #expect(try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8) == "archive payload")
        #expect(tab.canGoBack, "Back returns to the archive's folder")

        tab.goBack()
        try await eventually { tab.url == directory.url.normalizedFileURL && !tab.isLoading }
        tab.selection = [archive]
        tab.extractSelection(.folder(target, ownFolder: false, opens: false))
        // Not opened: this tab stays, with the archive still selected.
        try await eventually(timeout: .seconds(10)) { FileManager.default.fileExists(atPath: target.appendingPathComponent("note (2).txt").path) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(tab.url == directory.url.normalizedFileURL)
        #expect(tab.selection == [archive])
        try FileManager.default.removeItem(at: target.appendingPathComponent("note (2).txt"))
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

    /// A 7z with "Notes/a.txt", "Notes/photo.png" and a 1 MB "Notes/big.bin", plus its location.
    private func makeNotesArchive(in directory: TestDirectory) throws -> URL {
        let folder = try directory.folder("Notes")
        try "first".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: try #require(image.tiffRepresentation))?.representation(using: .png, properties: [:])
        try #require(png).write(to: folder.appendingPathComponent("photo.png"))
        try Data(repeating: 7, count: 1_000_000).write(to: folder.appendingPathComponent("big.bin"))
        let archive = try Archives.compress([folder], format: .sevenZip, fallbackFolder: directory.url)
        try FileManager.default.removeItem(at: folder)
        return archive
    }

    @Test func extractingReportsProgressAndCancellingCleansUp() async throws {
        let directory = try TestDirectory()
        let archive = try makeNotesArchive(in: directory)
        let total = try #require(ArchiveCatalog.shared.unpackedSize(of: [], in: archive))
        #expect(total > 1_000_000)
        #expect(ArchiveCatalog.shared.unpackedSize(of: ["Notes/a.txt"], in: archive) == 5)

        let progress = TransferProgress()
        let folder = try Archives.extractToFolder(archive, progress: progress, totalBytes: total)
        #expect(progress.completedBytes == total && progress.currentName == "Notes.7z")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Notes/big.bin").path))

        let cancelled = TransferProgress()
        cancelled.cancel()
        #expect(throws: CopyEngine.Cancelled.self) { try Archives.extractToFolder(archive, progress: cancelled, totalBytes: total) }
        #expect(!FileManager.default.fileExists(atPath: directory.path("Notes (3)").path))

        let transfer = FileTransfer(kind: .extract, itemCount: 2, source: ArchiveLocation(archive: archive).url, destination: directory.url)
        #expect(transfer.title == L10n.format("transfer.extract", 2, "Notes.7z", BrowserTab.displayName(of: directory.url)))
        let opening = FileTransfer(kind: .extract, itemCount: 1, source: ArchiveLocation(archive: archive).url,
                                   destination: ArchiveDirectory.temporaryRoot)
        #expect(opening.title == L10n.format("transfer.extract.open", 1, "Notes.7z"))
    }

    @Test func draggingArchiveItemsPromisesFilesAndDropsExtractThemInFoldera() async throws {
        let directory = try TestDirectory()
        let archive = try makeNotesArchive(in: directory)
        let note = ArchiveLocation(archive: archive, path: "Notes/a.txt")
        _ = try ArchiveCatalog.shared.children(of: ArchiveLocation(archive: archive))

        // Inside Foldera the drag carries the item's address.
        let pasteboard = NSPasteboard(name: .init("BrowserArchiveTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let writer = ItemPasteboard.writer(for: note.url)
        #expect(writer is ArchiveItemPromise)
        pasteboard.writeObjects([writer])
        #expect(ItemPasteboard.urls(from: pasteboard) == [note.url])

        let target = try directory.folder("target")
        #expect(FileDrop.operation(for: [note.url], into: target) == .copy)
        #expect(FileDrop.operation(for: [note.url], into: ArchiveLocation(archive: archive, path: "Notes").url) == nil)
        #expect(FileDrop.operation(for: [note.url, directory.url], into: target) == nil)
        #expect(FileDrop.perform([note.url], into: target))
        try await eventually(timeout: .seconds(10)) { FileManager.default.fileExists(atPath: target.appendingPathComponent("a.txt").path) }

        // Other apps get a file promise, kept by extracting where they ask.
        let promise = ArchiveItemPromise(itemURL: note.url)
        #expect(ArchivePromises.shared.filePromiseProvider(promise, fileNameForType: promise.fileType) == "a.txt")
        let destination = target.appendingPathComponent("dropped.txt")
        var result: Error?? = .none
        ArchivePromises.shared.filePromiseProvider(promise, writePromiseTo: destination) { error in
            Task { @MainActor in result = .some(error) }
        }
        try await eventually(timeout: .seconds(10)) { result != nil }
        #expect(result! == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "first")
    }

    @Test func changedArchivesInvalidateListingsPreviewsAndThumbnails() async throws {
        let directory = try TestDirectory()
        let source = try directory.file("note.txt", contents: "first")
        let archive = directory.path("notes.zip")
        let options = Archives.Options(format: .zip, level: .store)
        try Archives.compress([source], options: options, to: archive)
        let location = ArchiveLocation(archive: archive)
        let entry = try #require(ArchiveCatalog.shared.children(of: location).first)
        let url = location.child(entry).url
        let previews = ArchivePreviews()
        let oldCopy = try #require(await previews.file(for: url))
        #expect(try String(contentsOf: oldCopy, encoding: .utf8) == "first")
        let oldSignature = try ArchiveSignature(archive)
        let archiveDate = try #require(archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let sourceDate = try #require(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let oldSize = try Data(contentsOf: archive).count

        try Data("other".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)
        let replacement = directory.path("replacement.zip")
        try Archives.compress([source], options: options, to: replacement)
        try FileManager.default.setAttributes([.modificationDate: archiveDate], ofItemAtPath: replacement.path)
        #expect(try Data(contentsOf: replacement).count == oldSize)
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: replacement, to: archive)
        #expect(try ArchiveSignature(archive) != oldSignature)
        #expect(previews.cachedFile(for: url) == nil)
        #expect(try ArchiveCatalog.shared.children(of: location).map(\.path) == ["note.txt"])
        let newCopy = try #require(await previews.file(for: url))
        #expect(newCopy != oldCopy)
        #expect(try String(contentsOf: newCopy, encoding: .utf8) == "other")
        #expect(try String(contentsOf: oldCopy, encoding: .utf8) == "first", "a copy already open in Quick Look remains usable")

        let photoArchive = try makeNotesArchive(in: directory)
        let photoEntry = try #require(ArchiveCatalog.shared.children(of: ArchiveLocation(archive: photoArchive, path: "Notes")).first { $0.name == "photo.png" })
        let photo = FileItem(archiveEntry: photoEntry, in: photoArchive)
        #expect(await Thumbnails.shared.load(for: photo, size: 64, scale: 1) != nil)
        #expect(Thumbnails.shared.cached(for: photo, size: 64) != nil)
        try FileManager.default.removeItem(at: photoArchive)
        try Archives.compress([source], format: .sevenZip, to: photoArchive)
        #expect(Thumbnails.shared.cached(for: photo, size: 64) == nil)
        #expect(ArchivePreviews.shared.cachedFile(for: photo.url) == nil)
    }

    @Test func archiveItemsGetThumbnailsDetailsAndQuickLookFromCopies() async throws {
        let directory = try TestDirectory()
        let archive = try makeNotesArchive(in: directory)
        let root = ArchiveLocation(archive: archive)
        let items = try ArchiveCatalog.shared.children(of: ArchiveLocation(archive: archive, path: "Notes"))
            .map { FileItem(archiveEntry: $0, in: archive) }
        let photo = try #require(items.first { $0.name == "photo.png" })
        let text = try #require(items.first { $0.name == "a.txt" })
        #expect(Thumbnails.showsPreview(photo) && !Thumbnails.showsPreview(text))

        // Requests that arrive together come out in one go, each to its own copy.
        async let photoFile = ArchivePreviews.shared.file(for: photo.url)
        async let textFile = ArchivePreviews.shared.file(for: text.url)
        let (photoCopy, textCopy) = await (photoFile, textFile)
        #expect(photoCopy?.lastPathComponent == "photo.png" && textCopy?.lastPathComponent == "a.txt")
        #expect(ArchivePreviews.shared.cachedFile(for: photo.url) == photoCopy)
        _ = await Thumbnails.shared.load(for: photo, size: 64, scale: 1)

        let look = QuickLook.shared
        if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil { panel.orderOut(nil) }
        let big = ArchiveLocation(archive: archive, path: "Notes/big.bin").url
        var presented: [String] = []
        BrowserTab.errorPresenter = { presented.append($0.localizedDescription) }
        defer { BrowserTab.errorPresenter = nil }
        let prepared = await ArchivePreviews.shared.prepare([big])
        #expect(prepared, "\(presented)")
        look.toggle { [big] }
        try await eventually(timeout: .seconds(10)) { look.urls().count == 1 }
        #expect(look.urls()[0].lastPathComponent == "big.bin" && look.urls()[0].isFileURL)
        if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil { panel.orderOut(nil) }
        #expect(FileFormat.location(of: photo.url) == (root.displayPath as NSString).abbreviatingWithTildeInPath + "/Notes")
    }

    @Test func typedPathsGoThroughArchives() throws {
        let directory = try TestDirectory()
        let archive = try makeNotesArchive(in: directory)
        #expect(ArchiveLocation.resolve(archive.path + "/Notes/a.txt") == ArchiveLocation(archive: archive, path: "Notes/a.txt"))
        #expect(ArchiveLocation.resolve(archive.path + "/Notes/../Notes") == ArchiveLocation(archive: archive, path: "Notes"))
        #expect(ArchiveLocation.resolve(directory.url.path + "/missing/file") == nil)
        let plain = try directory.file("plain.txt", contents: "x")
        #expect(ArchiveLocation.resolve(plain.path + "/inside") == nil)
    }

    @Test func extractingFromAnArchiveWindowOpensTheResultInANewTab() async throws {
        let directory = try TestDirectory()
        let archive = try makeNotesArchive(in: directory)
        let target = try directory.folder("target")
        let tab = BrowserTab(url: ArchiveLocation(archive: archive, path: "Notes").url)
        try await eventually(timeout: .seconds(10)) { tab.items.count == 3 }
        var opened: [(URL, Set<URL>)] = []
        tab.openInNewTab = { opened.append(($0, $1)) }
        let note = try #require(tab.items.first { $0.name == "a.txt" }?.url.archiveLocation)

        tab.extract([note], from: archive, into: target, opens: false)
        try await eventually(timeout: .seconds(10)) { FileManager.default.fileExists(atPath: target.appendingPathComponent("a.txt").path) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(opened.isEmpty)

        tab.extract([note], from: archive, into: target, opens: true)
        try await eventually(timeout: .seconds(10)) { !opened.isEmpty }
        #expect(opened[0].0 == target.normalizedFileURL && opened[0].1 == [target.appendingPathComponent("a (2).txt").normalizedFileURL])
        #expect(tab.isInsideArchive, "The archive stays open in its own tab")

        // The window's hook opens a real tab with the items selected.
        let model = ExplorerWindowModel(url: ArchiveLocation(archive: archive).url)
        model.activeTab.openInNewTab?(target, [target.appendingPathComponent("a.txt").normalizedFileURL])
        #expect(model.tabs.count == 2 && model.activeTab.url == target.normalizedFileURL)
        try await eventually { !model.activeTab.isLoading }
        #expect(model.activeTab.selection == [target.appendingPathComponent("a.txt").normalizedFileURL])
    }
}
