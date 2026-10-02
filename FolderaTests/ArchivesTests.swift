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
