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
    @Test @MainActor func fallbackFailureJournalsOnlyItsOwnedRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaFallback-\(UUID())")
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let blocked = source.appendingPathComponent("blocked")
        try Data("must survive".utf8).write(to: blocked)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)
            try? fm.removeItem(at: root)
        }
        do {
            try CopyEngine.copyExclusively(source, to: destination, progress: TransferProgress(), baseBytes: 0)
            Issue.record("Expected unreadable child to fail")
        } catch let failure as FileChange.Failure {
            #expect(failure.remaining.createdURLs == [destination])
            #expect(failure.remaining.moveCleanups.isEmpty)
            #expect(FileOperations.exists(blocked) && FileOperations.exists(destination))
            let undo = FileUndo()
            undo.record(failure.remaining, name: "Copy")
            #expect(undo.undo() == nil)
            #expect(FileOperations.exists(blocked) && !FileOperations.exists(destination))
        }
    }

    @Test func fallbackPreservesSymbolicLinksAndReadOnlyDirectoryMetadata() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaFallbackLinks-\(UUID())")
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "missing-target")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            try? fm.removeItem(at: root)
        }
        try CopyEngine.copyExclusively(source, to: destination, progress: TransferProgress(), baseBytes: 0)
        #expect(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path) == "missing-target")
        #expect((try fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o555)
    }

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

    @Test func unreadableChildFailsAndPreservesSource() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaUnreadable-\(UUID())")
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let blocked = source.appendingPathComponent("blocked")
        try Data("good".utf8).write(to: source.appendingPathComponent("good"))
        try Data("must survive".utf8).write(to: blocked)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)
            try? fm.removeItem(at: root)
        }
        let destination = root.appendingPathComponent("destination")
        #expect(throws: (any Error).self) { try CopyEngine.copy(source, to: destination, progress: TransferProgress(), baseBytes: 0) }
        #expect(FileOperations.exists(blocked))
        #expect(!FileOperations.exists(destination))
    }

    @Test func cancellationDoesNotRemoveDanglingDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaDangling-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try Data("source".utf8).write(to: source)
        try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: "missing-target")
        let progress = TransferProgress()
        progress.cancel()
        #expect(throws: (any Error).self) { try CopyEngine.copy(source, to: destination, progress: progress, baseBytes: 0) }
        #expect(try fm.destinationOfSymbolicLink(atPath: destination.path) == "missing-target")
    }

    @Test func atomicCommitNeverReplacesExistingItems() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaCommit-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged"), destination = root.appendingPathComponent("destination")
        try Data("copy".utf8).write(to: staged)
        try Data("unrelated".utf8).write(to: destination)
        #expect(throws: (any Error).self) { try FileOperations.moveItem(staged, to: destination) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "unrelated")
        #expect(FileOperations.exists(staged))
        try fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try FileOperations.moveItem(staged, to: destination) }
        #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(FileOperations.exists(staged))
    }

    @Test func nativePathsRejectNullInsteadOfUsingTruncatedName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaNull-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination\0suffix")
        try Data("source".utf8).write(to: source)
        #expect(throws: FileOperations.OperationError.self) { try FileOperations.moveItem(source, to: destination) }
        #expect(throws: FileOperations.OperationError.self) { try CopyEngine.copy(source, to: destination, progress: TransferProgress(), baseBytes: 0) }
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["source"])
    }
}
