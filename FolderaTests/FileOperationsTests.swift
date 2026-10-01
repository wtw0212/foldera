import Foundation
import Testing
@testable import Foldera

@MainActor
struct FileOperationsTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
    }

    @Test func newFolderNamesFollowExplorer() throws {
        #expect(try FileOperations.newFolder(in: directory).lastPathComponent == "New folder")
        #expect(try FileOperations.newFolder(in: directory).lastPathComponent == "New folder (2)")
        #expect(try FileOperations.newFolder(in: directory).lastPathComponent == "New folder (3)")
    }

    @Test func copyIntoSameFolderAddsCopySuffix() async throws {
        touch("report.txt")
        let source = directory.appendingPathComponent("report.txt")
        let first = try await FileOperations.copy([source], into: directory)
        let second = try await FileOperations.copy([source], into: directory)
        #expect(first.map(\.lastPathComponent) == ["report - Copy.txt"])
        #expect(second.map(\.lastPathComponent) == ["report - Copy (2).txt"])
    }

    @Test func renameRejectsInvalidAndDuplicateNames() throws {
        touch("a.txt")
        touch("b.txt")
        let a = directory.appendingPathComponent("a.txt")
        #expect(throws: FileOperations.OperationError.self) { try FileOperations.rename(a, to: "bad/name") }
        #expect(throws: FileOperations.OperationError.self) { try FileOperations.rename(a, to: "  ") }
        #expect(throws: FileOperations.OperationError.self) { try FileOperations.rename(a, to: "b.txt") }
        #expect(try FileOperations.rename(a, to: "c.txt").lastPathComponent == "c.txt")
    }

    @Test func renameAllowsCaseOnlyChange() throws {
        touch("readme.md")
        let renamed = try FileOperations.rename(directory.appendingPathComponent("readme.md"), to: "README.md")
        #expect(renamed.lastPathComponent == "README.md")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["README.md"])
    }

    @Test func listedFolderURLsMatchBuiltURLs() async throws {
        let created = try FileOperations.newFolder(in: directory)
        let items = try await DirectoryLoader.load(directory)
        #expect(items.map(\.url) == [created.normalizedFileURL])
    }

    @Test func titleHidesExtensionOnlyForFiles() {
        touch("photo.jpeg")
        let file = FileItem(url: directory.appendingPathComponent("photo.jpeg"))
        #expect(file.title(showExtensions: false) == "photo")
        #expect(file.title(showExtensions: true) == "photo.jpeg")
    }
}

struct CopyEngineTests {
    @Test func copiesFolderTreeAndReportsBytes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaCopy-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src/inner")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 10_000).write(to: source.appendingPathComponent("a.bin"))
        try Data(repeating: 1, count: 2_000).write(to: root.appendingPathComponent("src/b.bin"))

        let progress = TransferProgress()
        let destination = root.appendingPathComponent("dst")
        #expect(CopyEngine.size(of: root.appendingPathComponent("src")) == 12_000)
        try CopyEngine.copy(root.appendingPathComponent("src"), to: destination, progress: progress, baseBytes: 0)
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("inner/a.bin").path))
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("b.bin").path))
    }

    @Test func refusesToOverwriteAndKeepsExistingItem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaCopy-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        #expect(throws: (any Error).self) { try CopyEngine.copy(a, to: b, progress: TransferProgress(), baseBytes: 0) }
        #expect(try String(contentsOf: b, encoding: .utf8) == "b")
    }
}
