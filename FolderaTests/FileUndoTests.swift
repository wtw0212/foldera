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

    @Test func partialUndoKeepsPendingAndCompletedEntriesRecoverable() throws {
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        let x = root.appendingPathComponent("dest/x"), y = root.appendingPathComponent("dest/y")
        try Data("A".utf8).write(to: x)
        try Data("B".utf8).write(to: y)
        let undo = FileUndo()
        undo.record(.moved([(a, x), (b, y)]), name: "Move")
        #expect(undo.undo() != nil)
        #expect(undo.canUndo && undo.canRedo)
        #expect(exists("b.txt") && !exists("dest/y") && exists("dest/x"))
        try fm.removeItem(at: a)
        #expect(undo.undo() == nil)
        #expect(!undo.canUndo && undo.canRedo)
        #expect(undo.redo() == nil)
        #expect(undo.redo() == nil)
        #expect(try String(contentsOf: x, encoding: .utf8) == "A")
        #expect(try String(contentsOf: y, encoding: .utf8) == "B")
        #expect(!exists("a.txt") && !exists("b.txt"))
    }

    @Test func partialRedoKeepsBothDirectionsRecoverable() throws {
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        let x = root.appendingPathComponent("dest/x"), y = root.appendingPathComponent("dest/y")
        try fm.removeItem(at: a)
        try Data("A".utf8).write(to: x)
        try Data("B".utf8).write(to: y)
        let undo = FileUndo()
        undo.record(.moved([(a, x), (b, y)]), name: "Move")
        #expect(undo.undo() == nil)
        try Data("blocker".utf8).write(to: y)
        #expect(undo.redo() != nil)
        #expect(undo.canUndo && undo.canRedo)
        #expect(exists("dest/x") && exists("b.txt") && !exists("a.txt"))
        try fm.removeItem(at: y)
        #expect(undo.redo() == nil)
        #expect(undo.undo() == nil)
        #expect(undo.undo() == nil)
        #expect(try String(contentsOf: a, encoding: .utf8) == "A")
        #expect(try String(contentsOf: b, encoding: .utf8) == "B")
    }

    @Test func failedBatchUndoRollsBackAndRetainsEntry() throws {
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        let x = root.appendingPathComponent("dest/x"), y = root.appendingPathComponent("dest/y")
        try fm.removeItem(at: a)
        try Data("blocker".utf8).write(to: b)
        try Data("A".utf8).write(to: x)
        try Data("B".utf8).write(to: y)
        let undo = FileUndo()
        undo.record(.batchRenamed([(a, x), (b, y)]), name: "Rename")
        #expect(undo.undo() != nil)
        #expect(undo.canUndo && !undo.canRedo)
        #expect(try String(contentsOf: x, encoding: .utf8) == "A")
        #expect(try String(contentsOf: y, encoding: .utf8) == "B")
        #expect(!exists("a.txt"))
        try fm.removeItem(at: b)
        #expect(undo.undo() == nil)
        #expect(undo.redo() == nil)
    }

    @Test func partialDeleteReturnsUndoForSuccessfulTrashItems() throws {
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: false)
        let a = root.appendingPathComponent("a.txt"), b = locked.appendingPathComponent("b")
        try Data("B".utf8).write(to: b)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        do {
            try FileOperations.trash([a, b])
            Issue.record("Expected second Trash operation to fail")
        } catch let failure as FileChange.Failure {
            #expect(!FileOperations.exists(a) && FileOperations.exists(b))
            let undo = FileUndo()
            undo.record(failure.remaining, name: "Delete")
            #expect(undo.canUndo)
            #expect(undo.undo() == nil)
            #expect(FileOperations.exists(a) && FileOperations.exists(b))
        }
    }
}
