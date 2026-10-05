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
