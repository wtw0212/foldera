import Foundation
import Testing
@testable import Foldera

@MainActor
struct FileUndoTests {
    private let root: URL
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaUndo-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("dest"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
    }

    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }

    @Test func renameUndoAndRedo() throws {
        let a = root.appendingPathComponent("a.txt")
        let b = try FileOperations.rename(a, to: "b.txt")
        let redo = try FileUndo.revert(.renamed(from: a, to: b))
        #expect(exists("a.txt") && !exists("b.txt"))
        _ = try FileUndo.revert(redo)
        #expect(exists("b.txt") && !exists("a.txt"))
    }

    @Test func moveUndoPutsItemBack() async throws {
        let result = await FileTransfers.shared.run(.move, [root.appendingPathComponent("a.txt")], into: root.appendingPathComponent("dest"))
        #expect(exists("dest/a.txt"))
        _ = try FileUndo.revert(FileChange(result, kind: .move))
        #expect(exists("a.txt") && !exists("dest/a.txt"))
    }

    @Test func deleteUndoRestoresFromTrash() throws {
        let pairs = try FileOperations.trash([root.appendingPathComponent("a.txt")])
        #expect(!exists("a.txt"))
        _ = try FileUndo.revert(.trashed(pairs))
        #expect(exists("a.txt"))
    }

    @Test func copyUndoTrashesTheCopy() async throws {
        let result = await FileTransfers.shared.run(.copy, [root.appendingPathComponent("a.txt")], into: root.appendingPathComponent("dest"))
        let redo = try FileUndo.revert(FileChange(result, kind: .copy))
        #expect(!exists("dest/a.txt") && exists("a.txt"))
        _ = try FileUndo.revert(redo)
        #expect(exists("dest/a.txt"))
    }
}
