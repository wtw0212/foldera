import Foundation
import Testing
@testable import Foldera

struct ArchivesTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchivesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func namesAndDetection() {
        #expect(Archives.baseName(of: URL(fileURLWithPath: "/x/photos.tar.gz")) == "photos")
        #expect(Archives.baseName(of: URL(fileURLWithPath: "/x/Report.ZIP")) == "Report")
        #expect(Archives.isArchive(URL(fileURLWithPath: "/x/a.7z")))
        #expect(!Archives.isArchive(URL(fileURLWithPath: "/x/a.txt")))
        // Split archives: only the first part is offered; the rest are read through it.
        #expect(Archives.isArchive(URL(fileURLWithPath: "/x/movie.part1.rar")))
        #expect(!Archives.isArchive(URL(fileURLWithPath: "/x/movie.part2.rar")))
        #expect(Archives.isArchive(URL(fileURLWithPath: "/x/big.7z.001")))
        #expect(!Archives.isArchive(URL(fileURLWithPath: "/x/big.7z.002")))
        #expect(Archives.baseName(of: URL(fileURLWithPath: "/x/movie.part01.rar")) == "movie")
        #expect(Archives.baseName(of: URL(fileURLWithPath: "/x/big.7z.001")) == "big")
    }

    @Test func compressThenExtractRoundTrips() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "hello".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let single = try Archives.compress([folder], fallbackFolder: root)
        #expect(single.lastPathComponent == "docs.zip")
        let multi = try Archives.compress([folder, root.appendingPathComponent("b.txt")], fallbackFolder: root)
        #expect(multi.lastPathComponent == "Archive.zip")

        // Extract to its own folder: "docs" exists, so the new folder is "docs (2)".
        let extracted = try Archives.extractToFolder(single)
        #expect(extracted.lastPathComponent == "docs (2)")
        #expect(try String(contentsOf: extracted.appendingPathComponent("docs/a.txt"), encoding: .utf8) == "hello")

        // Extract here never overwrites: both names already exist, so both get kept as copies.
        let added = try Archives.extractHere(multi, into: root).map(\.lastPathComponent).sorted()
        #expect(added == ["b (2).txt", "docs (3)"])
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "world")
    }

    @Test(arguments: [(Archives.Format.zip, 1), (.zip, 2), (.sevenZip, 2)])
    func compressingReportsProgress(format: Archives.Format, itemCount: Int) throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var items: [URL] = []
        for index in 0..<itemCount {
            let folder = root.appendingPathComponent("folder \(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for file in 0..<3 { try Data(repeating: UInt8(file), count: 200_000).write(to: folder.appendingPathComponent("\(file).bin")) }
            items.append(folder)
        }
        let progress = TransferProgress()
        let archive = try Archives.compress(items, format: format, fallbackFolder: root, progress: progress)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(progress.completedBytes == Int64(itemCount * 600_000), "progress reaches the full size")
    }

    @Test func cancellingCompressionRemovesThePartialArchive() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 1_000_000).write(to: file)
        let progress = TransferProgress()
        progress.cancel()
        #expect(throws: CopyEngine.Cancelled.self) { try Archives.compress([file], fallbackFolder: root, progress: progress) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("big.bin.zip").path))
    }

    @Test(arguments: [Archives.Format.zip, .sevenZip])
    func cancellingMultiFolderCompressionStopsBeforeCopying(format: Archives.Format) throws {
        let directory = try TestDirectory()
        let first = try directory.file("a/first.txt", contents: "KEEP")
        let missing = directory.path("b/missing.txt")
        let progress = TransferProgress()
        progress.cancel()
        let archive = directory.path("cancelled.zip")
        #expect(throws: CopyEngine.Cancelled.self) {
            try Archives.compress([first, missing], format: format, to: archive, progress: progress)
        }
        #expect(!FileOperations.exists(archive))
        #expect(try String(contentsOf: first, encoding: .utf8) == "KEEP")
    }

    /// Staging has its own byte counter, but cancellation must still propagate from the compression job.
    @Test func stagingCopiesShareCancellationWithoutAdvancingCompressionProgress() throws {
        let directory = try TestDirectory()
        let source = try directory.file("source.txt", contents: "KEEP")
        let job = TransferProgress(), staging = TransferProgress(cancellationSource: job)
        try CopyEngine.copy(source, to: directory.path("first.txt"), progress: staging, baseBytes: 0)
        #expect(job.completedBytes == 0 && !staging.isCancelled)
        job.cancel()
        #expect(throws: CopyEngine.Cancelled.self) {
            try CopyEngine.copy(source, to: directory.path("second.txt"), progress: staging, baseBytes: 0)
        }
        #expect(!FileOperations.exists(directory.path("second.txt")))
        #expect(try String(contentsOf: source, encoding: .utf8) == "KEEP")
    }

    @Test(arguments: ["-notes", "-m", "-@"])
    func selectedLinksBeginningWithADashAreLiteralZipOperands(name: String) throws {
        let directory = try TestDirectory()
        let target = try directory.file("private.txt", contents: "SECRET")
        let link = directory.path(name)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.lastPathComponent)
        let archive = directory.path("selection.zip")
        try Archives.compress([link], to: archive)
        #expect(try entries(of: archive) == [name])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.lastPathComponent)
        #expect(try String(contentsOf: target, encoding: .utf8) == "SECRET")
    }

    /// Paths stored in `archive`, as 7-Zip lists them (macOS metadata left out).
    private func entries(of archive: URL) throws -> [String] {
        let list = Process(), pipe = Pipe()
        list.executableURL = try #require(Archives.sevenZip)
        list.arguments = ["l", "-slt", "-ba", archive.path]
        list.standardOutput = pipe
        try list.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        return output.split(separator: "\n").compactMap { line in
            line.hasPrefix("Path = ") ? String(line.dropFirst(7)) : nil
        }.filter { !$0.hasPrefix("__MACOSX") }.sorted()
    }

    /// Selected links and links inside selected folders are archived as links: their targets (here outside the
    /// selection) never end up in the archive, whichever way it is made.
    @Test(arguments: [Archives.Format.zip, .sevenZip], ["link", "folder", "same parent", "several folders"])
    func compressingStoresSymbolicLinksAsLinks(format: Archives.Format, selection: String) throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("private"), withIntermediateDirectories: false)
        try "SECRET".write(to: root.appendingPathComponent("private/secret.txt"), atomically: true, encoding: .utf8)
        for folder in ["a/docs", "b/docs"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            try "doc".write(to: root.appendingPathComponent("\(folder)/note.txt"), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("a/docs/inner").path, withDestinationPath: "../../private")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("a/top").path, withDestinationPath: "../private")
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        let items: [URL] = switch selection {
        case "link": [a.appendingPathComponent("top")]
        case "folder": [a.appendingPathComponent("docs")]
        case "same parent": [a.appendingPathComponent("docs"), a.appendingPathComponent("top")]
        default: [a.appendingPathComponent("docs"), b.appendingPathComponent("docs"), a.appendingPathComponent("top")]
        }

        let archive = try Archives.compress(items, format: format, fallbackFolder: root)
        let stored = try entries(of: archive)
        #expect(!stored.contains { $0.hasSuffix("secret.txt") }, "a link's target is never archived: \(stored)")
        if selection != "folder" { #expect(stored.contains("top")) }
        if selection != "link" { #expect(stored.contains("docs/inner") && stored.contains("docs/note.txt")) }
        if selection == "several folders" {
            #expect(stored.filter { $0.hasSuffix("/note.txt") }.count == 2, "same-named items from different folders are both kept")
        }
        // Compressing several folders' items never touches the originals.
        #expect(try fm.destinationOfSymbolicLink(atPath: a.appendingPathComponent("top").path) == "../private")
    }

    @Test func sevenZipIsBundled() {
        #expect(Archives.sevenZip != nil)
        #expect(Bundle.main.url(forResource: "7-Zip-License", withExtension: "txt") != nil)
    }

    @Test func sevenZipRoundTripAndTarGz() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "jpg".write(to: folder.appendingPathComponent("1.jpg"), atomically: true, encoding: .utf8)

        let archive = try Archives.compress([folder], format: .sevenZip, fallbackFolder: root)
        #expect(archive.lastPathComponent == "photos.7z")
        let out = try Archives.extractToFolder(archive)
        #expect(try String(contentsOf: out.appendingPathComponent("photos/1.jpg"), encoding: .utf8) == "jpg")

        // tar.gz unpacks both layers in one go (bsdtar), not just to a .tar.
        let tgz = root.appendingPathComponent("photos.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tgz.path, "-C", root.path, "photos"]
        try tar.run()
        tar.waitUntilExit()
        let fromTar = try Archives.extractToFolder(tgz)
        #expect(FileManager.default.fileExists(atPath: fromTar.appendingPathComponent("photos/1.jpg").path))
    }

    @Test func encryptedArchiveAsksForPasswordAndRejectsWrongOne() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("secret.txt")
        try "s3cret".write(to: source, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("locked.7z")
        let sevenZip = try #require(Archives.sevenZip)
        let make = Process()
        make.executableURL = sevenZip
        make.arguments = ["a", "-bso0", "-bsp0", "-pletmein", "-mhe=on", archive.path, source.path]
        try make.run()
        make.waitUntilExit()
        #expect(make.terminationStatus == 0)

        do {
            _ = try Archives.extractToFolder(archive)
            Issue.record("expected a password request")
        } catch let needed as Archives.PasswordRequired {
            #expect(!needed.wasWrong)
        }
        do {
            _ = try Archives.extractToFolder(archive, password: "nope")
            Issue.record("expected a wrong-password request")
        } catch let needed as Archives.PasswordRequired {
            #expect(needed.wasWrong)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("locked").path))
        let out = try Archives.extractToFolder(archive, password: "letmein")
        #expect(try String(contentsOf: out.appendingPathComponent("secret.txt"), encoding: .utf8) == "s3cret")
    }

    /// Which characters a throwaway passphrase uses; it is generated per run, never written in the source.
    enum Phrase { case none, ascii, unicode }

    @Test(arguments: [
        (Archives.Options(format: .zip, level: .maximum, zipEncryption: .aes256), Phrase.ascii),
        (Archives.Options(format: .zip, level: .store, zipEncryption: .zipCrypto), .ascii),
        (Archives.Options(format: .zip, level: .fastest), .none),
        (Archives.Options(format: .sevenZip, level: .ultra, encryptNames: true), .unicode),
        (Archives.Options(format: .sevenZip, level: .store, encryptNames: false), .ascii),
    ])
    func compressingWithOptionsRoundTrips(options: Archives.Options, phrase: Phrase) throws {
        var options = options
        switch phrase {
        case .none: break
        case .ascii: options.password = UUID().uuidString + " !~"
        case .unicode: options.password = UUID().uuidString + " äö 中文"
        }
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "hello".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "a.txt")

        let archive = root.appendingPathComponent(Archives.fileName("My Docs", format: options.format))
        try Archives.compress([folder], options: options, to: archive, progress: TransferProgress())

        if options.hasPassword {
            do {
                _ = try Archives.extractToFolder(archive)
                Issue.record("expected a password request")
            } catch let needed as Archives.PasswordRequired {
                #expect(!needed.wasWrong)
            }
            #expect(throws: Archives.PasswordRequired.self) { try Archives.extractToFolder(archive, password: "nope") }
        }
        let out = try Archives.extractToFolder(archive, password: options.password)
        #expect(out.lastPathComponent == "My Docs")
        #expect(try String(contentsOf: out.appendingPathComponent("docs/a.txt"), encoding: .utf8) == "hello")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("docs/link").path) == "a.txt")
    }

    @Test func compressOptionsValidateNamesPasswordsAndDestinations() throws {
        #expect(Archives.fileName("Report", format: .zip) == "Report.zip")
        #expect(Archives.fileName(" Report.ZIP ", format: .zip) == "Report.ZIP")
        #expect(Archives.fileName("Report.zip", format: .sevenZip) == "Report.zip.7z")
        #expect(Archives.Options.isValidPassword("Ab1 !~", for: .zip))
        #expect(!Archives.Options.isValidPassword("密碼", for: .zip))
        #expect(Archives.Options.isValidPassword("密碼", for: .sevenZip))

        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("a.zip")
        #expect(throws: Archives.Failure.self) {
            try Archives.compress([file], options: Archives.Options(format: .zip, password: "密碼"), to: zip)
        }
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        // An archive inside a folder it compresses would contain itself.
        #expect(throws: FileOperations.OperationError.self) {
            try Archives.compress([root], options: Archives.Options(format: .sevenZip), to: root.appendingPathComponent("self.7z"))
        }
    }

    @Test func listingReadsEntriesAndImpliedFolders() throws {
        let output = """
        Path = docs/a b.txt
        Folder = -
        Size = 12
        Modified = 2026-10-05 18:21:56.5
        Attributes =  -rw-r--r--

        Path = docs/link
        Size = 5
        Attributes =  lrwxr-xr-x

        Path = ../escape.txt
        Size = 1

        Path = top
        Attributes = D drwxr-xr-x
        """
        let entries = Archives.parseListing(output)
        #expect(entries.map(\.path) == ["docs/a b.txt", "docs/link", "top"])
        #expect(entries[0].size == 12 && entries[0].modified != nil && !entries[0].isDirectory)
        #expect(entries[1].isSymlink && entries[2].isDirectory && entries[2].size == nil)

        let location = ArchiveLocation(archive: URL(fileURLWithPath: "/tmp/My #1 100%.7z"), path: "/docs//中文/./")
        #expect(location.path == "docs/中文" && location.name == "中文")
        #expect(location.url.archiveLocation == location && location.url.isInArchive && !location.url.isFileURL)
        #expect(location.parent == ArchiveLocation(archive: location.archive, path: "docs"))
        #expect(location.ancestors.map(\.name) == ["My #1 100%.7z", "docs", "中文"])
        #expect(ArchiveLocation(archive: location.archive).parent == nil)
        #expect(FileKind.of(ArchiveLocation(archive: location.archive, path: "x/photo.png").url, type: nil) == .image)
    }

    @Test func catalogListsFoldersOfARealArchive() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        // zip -D leaves folders out, so "docs" and "docs/sub" exist only in the files' paths.
        let archive = root.appendingPathComponent("docs.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", "-D", archive.path, "docs"]
        zip.currentDirectoryURL = root
        try zip.run()
        zip.waitUntilExit()

        let catalog = ArchiveCatalog()
        let top = try catalog.children(of: ArchiveLocation(archive: archive))
        #expect(top.map(\.name) == ["docs"] && top[0].isDirectory)
        #expect(try catalog.children(of: ArchiveLocation(archive: archive, path: "docs")).map(\.name) == ["sub"])
        #expect(try catalog.children(of: ArchiveLocation(archive: archive, path: "docs/sub")).map(\.name) == ["a.txt"])
        #expect(throws: CocoaError.self) { try catalog.children(of: ArchiveLocation(archive: archive, path: "nope")) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        try ArchiveDirectory.extract([ArchiveLocation(archive: archive, path: "docs/sub")], from: archive, into: out, catalog: catalog)
        #expect(try String(contentsOf: out.appendingPathComponent("docs/sub/a.txt"), encoding: .utf8) == "a")
        #expect(Archives.isBrowsable(archive) && !Archives.isBrowsable(root.appendingPathComponent("x.tar.gz")))
    }

    @Test func brokenArchiveReportsErrorAndLeavesNoFolder() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.zip")
        try "not a zip".write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: Archives.Failure.self) { try Archives.extractToFolder(bad) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
    }
}

struct FileKindTests {
    @Test func classifiesCommonFiles() {
        func kind(_ name: String) -> FileKind { FileKind.of(URL(fileURLWithPath: "/x/" + name), type: nil) }
        #expect(kind("a.jpg") == .image)
        #expect(kind("a.mp4") == .video)
        #expect(kind("a.mp3") == .audio)
        #expect(kind("a.zip") == .archive)
        #expect(kind("a.7z") == .archive)
        #expect(kind("a.rar") == .archive)
        #expect(kind("a.dmg") == .diskImage)
        #expect(kind("a.bin") != .archive)
        #expect(kind("a.pdf") == .pdf)
        #expect(kind("a.docx") == .document)
        #expect(kind("a.xlsx") == .spreadsheet)
        #expect(kind("a.pptx") == .presentation)
        #expect(kind("a.swift") == .code)
        #expect(kind("a.sh") == .script)
        #expect(kind("a.txt") == .text)
    }
}
