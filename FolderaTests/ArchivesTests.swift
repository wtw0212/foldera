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

    @Test func brokenArchiveReportsErrorAndLeavesNoFolder() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.zip")
        try "not a zip".write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: Archives.Failure.self) { try Archives.extractToFolder(bad) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
    }
}
