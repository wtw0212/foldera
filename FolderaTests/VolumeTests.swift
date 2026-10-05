import Foundation
import Testing
@testable import Foldera

@MainActor
@Suite(.serialized)
struct VolumeTests {
    private func makeTree(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
    }

    private func expectComplete(_ directory: URL) throws {
        for name in ["a", "b", "c"] {
            #expect(try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) == name)
        }
    }

    @Test func compressionKeepsBothOnVolumesWithoutExclusiveRename() async throws {
        try await withVolume("MS-DOS") { root, volume in
            #expect(!FileOperations.supportsExclusiveRename(in: volume))
            let source = root.appendingPathComponent("note.txt")
            try Data("payload".utf8).write(to: source)
            let existing = volume.appendingPathComponent("Archive.7z")
            try Data("KEEP".utf8).write(to: existing)
            let archive = try Archives.compress([source], options: Archives.Options(format: .sevenZip), named: "Archive", in: volume)
            #expect(archive.lastPathComponent == "Archive (2).7z")
            #expect(try String(contentsOf: existing, encoding: .utf8) == "KEEP")
            let extracted = try Archives.extractToFolder(archive, in: root)
            #expect(try String(contentsOf: extracted.appendingPathComponent("note.txt"), encoding: .utf8) == "payload")
        }
    }

    @Test func partiallyDeletedMoveSourceIsRebuiltBeforeUndoRemovesCompleteCopy() async throws {
        try await withVolume("HFS+") { root, volume in
            let fm = FileManager()
            let source = volume.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try makeTree(source)
            let delegate = PartialRemovalDelegate(blocked: source.appendingPathComponent("b"))
            let previous = fm.delegate
            fm.delegate = delegate
            defer { fm.delegate = previous }
            let plan = FileTransfers.planItem(.move, source: source, destination: destination)
            #expect(!plan.isRename)
            let result = FileTransfers.execute([plan], progress: TransferProgress(), fileManager: fm)
            #expect(result.error != nil && result.created.isEmpty && result.moved.isEmpty)
            #expect(result.moveCleanups.count == 1 && result.results == [destination])
            #expect(try fm.contentsOfDirectory(atPath: source.path) == ["b"])
            try expectComplete(destination)
            fm.delegate = previous
            let undo = FileUndo(fileManager: fm)
            undo.record(FileChange(result, kind: .move), name: "Move")
            #expect(undo.undo() == nil)
            try expectComplete(source)
            #expect(!FileOperations.exists(destination))
            // Redo restores the exact partial state; the full destination must remain authoritative.
            #expect(undo.redo() == nil)
            #expect(try fm.contentsOfDirectory(atPath: source.path) == ["b"])
            try expectComplete(destination)
            #expect(undo.undo() == nil)
            try expectComplete(source)
            #expect(!FileOperations.exists(destination))
        }
    }

    @Test(arguments: [false, true])
    func inversePartialRemovalRebuildsFromCompleteCopy(redo: Bool) async throws {
        try await withVolume("HFS+") { root, volume in
            let fm = FileManager()
            let source = root.appendingPathComponent("source"), destination = volume.appendingPathComponent("destination")
            try makeTree(source)
            try FileOperations.moveItem(source, to: destination)
            let undo = FileUndo(fileManager: fm)
            undo.record(.moved([(source, destination)]), name: "Move")
            if redo { #expect(undo.undo() == nil) }
            let partiallyRemoved = redo ? source : destination
            let authoritative = redo ? destination : source
            let delegate = PartialRemovalDelegate(blocked: partiallyRemoved.appendingPathComponent("b"))
            let previous = fm.delegate
            fm.delegate = delegate
            defer { fm.delegate = previous }
            #expect((redo ? undo.redo() : undo.undo()) != nil)
            #expect(try fm.contentsOfDirectory(atPath: partiallyRemoved.path) == ["b"])
            try expectComplete(authoritative)
            fm.delegate = previous
            #expect((redo ? undo.undo() : undo.redo()) == nil)
            try expectComplete(partiallyRemoved)
            #expect(!FileOperations.exists(authoritative))
        }
    }

    @Test func fatCopyFitsOnePayloadAndCountsFallbackMoveProgress() async throws {
        try await withVolume("MS-DOS") { root, volume in
            let bytes = 20 * 1024 * 1024
            let source = root.appendingPathComponent("large"), destination = volume.appendingPathComponent("large")
            try Data(repeating: 7, count: bytes).write(to: source)
            let available = try #require(volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
            #expect(available > bytes && available < 2 * bytes)
            let progress = TransferProgress(), finished = TransferProgress(), rewound = TransferProgress()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                var last: Int64 = 0
                while !finished.isCancelled {
                    let current = progress.completedBytes
                    if current < last { rewound.cancel() }
                    last = current
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            defer { finished.cancel(); group.wait() }
            try CopyEngine.copy(source, to: destination, progress: progress, baseBytes: 0)
            finished.cancel()
            group.wait()
            #expect(!rewound.isCancelled && progress.completedBytes == Int64(bytes))
            #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
            let plan = FileTransfers.planItem(.move, source: destination, destination: volume.appendingPathComponent("moved"))
            #expect(FileOperations.sameVolume(destination, volume) && !plan.isRename)
            #expect(plan.deleteSourceAfterCopy && FileTransfers.totalBytes([plan]) == Int64(bytes))
        }
    }

    @Test func symlinkedDestinationCannotRecursivelyCopyOnFAT() async throws {
        try await withVolume("MS-DOS") { root, volume in
            let source = volume.appendingPathComponent("source")
            let child = source.appendingPathComponent("subdir")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("KEEP".utf8).write(to: source.appendingPathComponent("keep"))
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
            let destination = link.appendingPathComponent("source")
            #expect(!FileOperations.supportsExclusiveRename(in: child))
            #expect(throws: FileOperations.OperationError.invalidDestination(destination.path)) {
                try CopyEngine.copyExclusively(source, to: destination, progress: TransferProgress(), baseBytes: 0)
            }
            #expect(throws: FileOperations.OperationError.invalidDestination(destination.path)) {
                try CopyEngine.copy(source, to: destination, progress: TransferProgress(), baseBytes: 0)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
            #expect(try String(contentsOf: source.appendingPathComponent("keep"), encoding: .utf8) == "KEEP")
        }
    }

    /// Real mounted filesystems, not a forced copy/delete branch. Images and mounts are disposable.
    private func withVolume(_ filesystem: String, perform: (URL, URL) throws -> Void) async throws {
        let fm = FileManager()
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaVolume-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = root.appendingPathComponent("disk.dmg")
        let mount = root.appendingPathComponent("mounted")
        func hdiutil(_ arguments: [String]) async throws {
            // Disk tools wait for AppKit's volume callbacks; let the main actor process them.
            try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let message = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "FolderaVolumeTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: message, as: UTF8.self)])
                }
            }.value
        }
        try await hdiutil(["create", "-size", "32m", "-fs", filesystem, "-volname", "FOLDERATEST", image.path])
        // FAT has no owners: with ownership on, files belong to the console user, and CI runners
        // have none, so the volume isn't writable there. Ownership doesn't matter for these tests.
        let owners = filesystem == "MS-DOS" ? "off" : "on"
        try await hdiutil(["attach", image.path, "-nobrowse", "-owners", owners, "-mountpoint", mount.path])
        var failure: Error?
        do { try perform(root, mount) } catch { failure = error }
        try? await hdiutil(["detach", mount.path])
        if let failure { throw failure }
    }

    @Test func crossVolumeUndoAndRedoJournalFailedSourceRemoval() async throws {
        try await withVolume("HFS+") { root, volume in
            let fm = FileManager()
            let source = root.appendingPathComponent("source")
            let directory = volume.appendingPathComponent("destination")
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent("source")
            try Data("complete copy".utf8).write(to: source)
            #expect(!FileOperations.sameVolume(source, directory))
            try FileOperations.moveItem(source, to: destination)
            #expect(!FileOperations.exists(source) && FileOperations.exists(destination))
            let undo = FileUndo(fileManager: fm)
            undo.record(.moved([(source, destination)]), name: "Move")
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
            #expect(undo.undo() != nil)
            #expect(undo.canUndo && undo.canRedo)
            #expect(try String(contentsOf: source, encoding: .utf8) == "complete copy")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "complete copy")
            // Redo must back up/rebuild the old source, so denied cleanup retains both complete copies.
            #expect(undo.redo() != nil)
            #expect(FileOperations.exists(source) && FileOperations.exists(destination))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            #expect(undo.redo() == nil)
            #expect(!FileOperations.exists(source) && FileOperations.exists(destination))
            #expect(undo.undo() == nil)
            #expect(FileOperations.exists(source) && FileOperations.exists(destination))
            #expect(undo.undo() == nil)
            #expect(FileOperations.exists(source) && !FileOperations.exists(destination))

            // Independently exercise deletion failure while redoing a successful cross-volume move.
            let redo = FileUndo()
            try FileOperations.moveItem(source, to: destination)
            redo.record(.moved([(source, destination)]), name: "Move")
            #expect(redo.undo() == nil)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
            #expect(redo.redo() != nil)
            #expect(redo.canUndo && redo.canRedo)
            #expect(try String(contentsOf: source, encoding: .utf8) == "complete copy")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "complete copy")
            #expect(redo.undo() != nil)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            #expect(redo.undo() == nil)
            #expect(FileOperations.exists(source) && !FileOperations.exists(destination))
        }
    }

    @Test func volumeWithoutExclusiveRenameSupportsCopyMoveAndBulkRollback() async throws {
        try await withVolume("MS-DOS") { root, volume in
            let fm = FileManager()
            #expect(try volume.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming == false)
            let source = root.appendingPathComponent("source")
            try fm.createDirectory(at: source.appendingPathComponent("inner"), withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: source.appendingPathComponent("inner/file"))
            let copied = volume.appendingPathComponent("copied")
            try CopyEngine.copy(source, to: copied, progress: TransferProgress(), baseBytes: 0)
            #expect(try String(contentsOf: copied.appendingPathComponent("inner/file"), encoding: .utf8) == "payload")
            let moved = volume.appendingPathComponent("moved")
            try FileOperations.moveItem(copied, to: moved)
            #expect(!FileOperations.exists(copied))
            #expect(try String(contentsOf: moved.appendingPathComponent("inner/file"), encoding: .utf8) == "payload")

            // A fallback bulk staging move can also partially delete a source tree.
            let tree = volume.appendingPathComponent("tree")
            try makeTree(tree)
            let delegate = PartialRemovalDelegate(blocked: tree.appendingPathComponent("b"))
            let previous = fm.delegate
            fm.delegate = delegate
            defer { fm.delegate = previous }
            do {
                try BulkRename.apply([(tree, volume.appendingPathComponent("renamed-tree"))], fileManager: fm)
                Issue.record("Expected partial source removal during bulk staging")
            } catch let failure as FileChange.Failure {
                #expect(failure.remaining.moveCleanups.count == 1)
                #expect(try fm.contentsOfDirectory(atPath: tree.path) == ["b"])
                try expectComplete(try #require(failure.remaining.moveCleanups.first?.completeCopy))
                fm.delegate = previous
                let undo = FileUndo(fileManager: fm)
                undo.record(failure.remaining, name: "Rename")
                #expect(undo.undo() == nil)
                try expectComplete(tree)
            }

            let a = volume.appendingPathComponent("a"), b = volume.appendingPathComponent("b")
            try Data("A".utf8).write(to: a)
            try Data("B".utf8).write(to: b)
            try BulkRename.apply([(a, b), (b, a)])
            #expect(try String(contentsOf: a, encoding: .utf8) == "B")
            #expect(try String(contentsOf: b, encoding: .utf8) == "A")
            #expect(throws: (any Error).self) { try BulkRename.apply([(a, volume.appendingPathComponent("c")), (b, moved)]) }
            #expect(try String(contentsOf: a, encoding: .utf8) == "B")
            #expect(try String(contentsOf: b, encoding: .utf8) == "A")
            #expect(Set(try fm.contentsOfDirectory(atPath: volume.path)).isSuperset(of: ["a", "b", "moved"]))
            #expect(!(try fm.contentsOfDirectory(atPath: volume.path)).contains { $0.hasPrefix(".foldera-rename-") })

            // No staging helper preflight: exclusive creation itself must reject every occupied root.
            #expect(throws: (any Error).self) { try CopyEngine.copyExclusively(source, to: moved, progress: TransferProgress(), baseBytes: 0) }
            #expect(throws: (any Error).self) { try CopyEngine.copyExclusively(a, to: b, progress: TransferProgress(), baseBytes: 0) }
            #expect(try String(contentsOf: b, encoding: .utf8) == "A")
            #expect(try String(contentsOf: moved.appendingPathComponent("inner/file"), encoding: .utf8) == "payload")
        }
    }
}

/// Skipping one child still removes its siblings, then native recursive removal fails at the root.
/// This exercises a real partial deletion without depending on directory traversal order.
nonisolated private final class PartialRemovalDelegate: NSObject, FileManagerDelegate {
    let blockedPath: String

    init(blocked: URL) { blockedPath = blocked.resolvingSymlinksInPath().path }

    func fileManager(_ fileManager: FileManager, shouldRemoveItemAt url: URL) -> Bool {
        url.resolvingSymlinksInPath().path != blockedPath
    }
}
