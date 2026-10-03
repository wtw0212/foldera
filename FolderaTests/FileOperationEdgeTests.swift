import Foundation
import Testing
@testable import Foldera

struct FileOperationEdgeTests {
    @Test(arguments: ["", " ", ".", "..", "a/b", "a:b", "a\0b"])
    func invalidRenamesPreserveSource(name: String) throws {
        let directory = try TestDirectory()
        let source = try directory.file("source.txt", contents: "original")
        #expect(throws: FileOperations.OperationError.self) { try FileOperations.rename(source, to: name) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["source.txt"])
    }

    @Test func trimmedAndUnchangedRenamesKeepContents() throws {
        let directory = try TestDirectory(), source = try directory.file("source.txt")
        #expect(try FileOperations.rename(source, to: "source.txt") == source)
        let renamed = try FileOperations.rename(source, to: "  renamed.txt\n")
        #expect(renamed == directory.path("renamed.txt"))
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "payload")
    }

    @Test func uniqueNamesHandleMultipleDotsAndExtensionlessFiles() throws {
        let directory = try TestDirectory()
        for name in ["report.final.txt", "report.final (2).txt", "README", "README - Copy"] {
            try directory.file(name)
        }
        #expect(FileOperations.uniqueURL(named: "report.final.txt", in: directory.url).lastPathComponent == "report.final (3).txt")
        #expect(FileOperations.uniqueURL(named: "README", in: directory.url, copySuffix: true).lastPathComponent == "README - Copy (2)")
        #expect(FileOperations.uniqueURL(named: "new.txt", in: directory.url, copySuffix: true) == directory.path("new.txt"))
    }

    @Test func textDocumentsAreEmptyAndNeverOverwriteAnExistingFile() throws {
        let directory = try TestDirectory()
        let first = try FileOperations.newTextDocument(in: directory.url)
        try Data("keep me".utf8).write(to: first)
        let second = try FileOperations.newTextDocument(in: directory.url)
        #expect(second.lastPathComponent == "New Text Document (2).txt")
        #expect(try Data(contentsOf: second).isEmpty)
        #expect(try String(contentsOf: first, encoding: .utf8) == "keep me")
    }

    @Test func danglingSymlinksCountAsExistingItems() throws {
        let directory = try TestDirectory()
        let link = directory.path("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.path("missing"))
        #expect(FileOperations.exists(link) && !FileManager.default.fileExists(atPath: link.path))
        #expect(!FileOperations.exists(directory.path("missing")))
    }

    @Test func moveKeepsExistingDestinationAndSameParentIsANoOp() async throws {
        let directory = try TestDirectory()
        let source = try directory.file("note.txt", contents: "source")
        let target = try directory.folder("target")
        let existing = try directory.file("target/note.txt", contents: "keep")
        #expect(try await FileOperations.move([source], into: directory.url) == [source])
        let moved = try await FileOperations.move([source], into: target)
        #expect(moved == [directory.path("target/note (2).txt")] && !FileOperations.exists(source))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
    }
}
