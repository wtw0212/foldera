import Foundation
import Testing
@testable import Foldera

@MainActor
struct FileTransfersTests {
    private let root: URL
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaTransfer-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("dest"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("file.txt"))
    }

    @Test func copyIntoSameFolderMakesNamedCopy() async {
        let result = await FileTransfers.shared.run(.copy, [root.appendingPathComponent("file.txt")], into: root)
        #expect(result.created.map(\.lastPathComponent) == ["file - Copy.txt"])
        #expect(fm.fileExists(atPath: root.appendingPathComponent("file.txt").path))
    }

    @Test func moveRelocatesAndRecordsUndoInfo() async {
        let source = root.appendingPathComponent("file.txt")
        let result = await FileTransfers.shared.run(.move, [source], into: root.appendingPathComponent("dest"))
        #expect(!fm.fileExists(atPath: source.path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("dest/file.txt").path))
        #expect(result.moved.count == 1)
        #expect(result.moved.first?.from == source.normalizedFileURL)
    }

    @Test func moveIntoSameFolderDoesNothing() async {
        let result = await FileTransfers.shared.run(.move, [root.appendingPathComponent("file.txt")], into: root)
        #expect(result.results.isEmpty)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("file.txt").path))
    }

    @Test func preparingTransferIsVisibleAndCancellationPreventsTheCopy() async throws {
        let transfer = FileTransfer(kind: .copy, itemCount: 1, source: root, destination: root.appendingPathComponent("dest"))
        let source = root.appendingPathComponent("file.txt"), destination = root.appendingPathComponent("dest/file.txt")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task {
            try await FileTransfers.shared.track(transfer, preparing: { progress in
                progress.setCurrentName("scanning")
                release.wait()
                return try CopyEngine.size(of: source, progress: progress)
            }) { progress in
                try CopyEngine.copy(source, to: destination, progress: progress, baseBytes: 0)
            }
        }
        try await eventually { transfer.progress.currentName == "scanning" }
        #expect(transfer.isPreparing && transfer.bytesPerSecond == 0)
        #expect(FileTransfers.shared.active.contains { $0.id == transfer.id })
        transfer.cancel()
        release.signal()
        await #expect(throws: CopyEngine.Cancelled.self) { try await task.value }
        #expect(!FileOperations.exists(destination))
        #expect(!FileTransfers.shared.active.contains { $0.id == transfer.id })
    }

    @Test func failedSourceRemovalRecordsAuthoritativeCopy() throws {
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: false)
        let source = locked.appendingPathComponent("source"), destination = root.appendingPathComponent("dest/source")
        try Data("complete copy".utf8).write(to: source)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        let plan = FileTransfers.PlanItem(source: source, destination: destination, isRename: false, deleteSourceAfterCopy: true)
        let result = FileTransfers.execute([plan], progress: TransferProgress())
        #expect(result.error != nil)
        #expect(result.created.isEmpty && result.results == [destination])
        #expect(result.moveCleanups.count == 1)
        #expect(result.moveCleanups.first?.source == source && result.moveCleanups.first?.completeCopy == destination)
        #expect(result.moved.isEmpty)
        #expect(FileOperations.exists(source))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "complete copy")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        let redo = try FileUndo.revert(FileChange(result, kind: .move))
        #expect(!FileOperations.exists(destination))
        _ = try FileUndo.revert(redo)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "complete copy")
    }

    @Test func incompleteCopyNeverDeletesMoveSource() throws {
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        let blocked = source.appendingPathComponent("blocked"), destination = root.appendingPathComponent("dest/source")
        try Data("good".utf8).write(to: source.appendingPathComponent("good"))
        try Data("must survive".utf8).write(to: blocked)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)
            try? fm.removeItem(at: root)
        }
        let plan = FileTransfers.PlanItem(source: source, destination: destination, isRename: false, deleteSourceAfterCopy: true)
        let result = FileTransfers.execute([plan], progress: TransferProgress())
        #expect(result.error != nil && result.results.isEmpty)
        #expect(FileOperations.exists(blocked) && FileOperations.exists(source.appendingPathComponent("good")))
        #expect(!FileOperations.exists(destination))
    }

    @Test func failedReplaceRestoresCurrentAndLeavesLaterDestinationsAlone() throws {
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("dest/a"), b = root.appendingPathComponent("dest/b")
        try Data("old A".utf8).write(to: a)
        try Data("old B".utf8).write(to: b)
        let plan = [
            FileTransfers.PlanItem(source: root.appendingPathComponent("missing"), destination: a, isRename: false, deleteSourceAfterCopy: false, replaceExisting: true),
            FileTransfers.PlanItem(source: root.appendingPathComponent("file.txt"), destination: b, isRename: false, deleteSourceAfterCopy: false, replaceExisting: true),
        ]
        let result = FileTransfers.execute(plan, progress: TransferProgress())
        #expect(result.error != nil && result.results.isEmpty && result.replaced.isEmpty)
        #expect(try String(contentsOf: a, encoding: .utf8) == "old A")
        #expect(try String(contentsOf: b, encoding: .utf8) == "old B")
    }

    @Test func cancelledReplaceNeverTrashesUnattemptedDestination() throws {
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("dest/file.txt")
        try Data("old".utf8).write(to: destination)
        let plan = FileTransfers.PlanItem(source: root.appendingPathComponent("file.txt"), destination: destination, isRename: false, deleteSourceAfterCopy: false, replaceExisting: true)
        let progress = TransferProgress()
        progress.cancel()
        let result = FileTransfers.execute([plan], progress: progress)
        #expect(result.error is CopyEngine.Cancelled)
        #expect(result.replaced.isEmpty && result.results.isEmpty)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "old")
    }

    @Test func replacementUndoAndRedoRestoreBothVersions() throws {
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("file.txt"), destination = root.appendingPathComponent("dest/file.txt")
        try Data("old".utf8).write(to: destination)
        let plan = FileTransfers.PlanItem(source: source, destination: destination, isRename: false, deleteSourceAfterCopy: false, replaceExisting: true)
        let result = FileTransfers.execute([plan], progress: TransferProgress())
        #expect(result.error == nil && result.replaced.count == 1)
        let undo = FileUndo()
        undo.record(FileChange(result, kind: .copy), name: "Replace")
        #expect(undo.undo() == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "old")
        #expect(undo.redo() == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "hello")
        #expect(undo.undo() == nil)
    }
}
