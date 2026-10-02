import Foundation
import Testing
@testable import Foldera

@MainActor
struct VolumeTests {
    /// Real mounted filesystems, not a forced copy/delete branch. Images and mounts are disposable.
    private func withVolume(_ filesystem: String, perform: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaVolume-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = root.appendingPathComponent("disk.dmg")
        let mount = root.appendingPathComponent("mounted")
        func hdiutil(_ arguments: [String]) throws {
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
        }
        try hdiutil(["create", "-size", "32m", "-fs", filesystem, "-volname", "FOLDERATEST", image.path])
        try hdiutil(["attach", image.path, "-nobrowse", "-owners", "on", "-mountpoint", mount.path])
        defer { try? hdiutil(["detach", mount.path]) }
        try perform(root, mount)
    }

    @Test func crossVolumeUndoAndRedoJournalFailedSourceRemoval() async throws {
        try withVolume("HFS+") { root, volume in
            let fm = FileManager.default
            let source = root.appendingPathComponent("source")
            let directory = volume.appendingPathComponent("destination")
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent("source")
            try Data("complete copy".utf8).write(to: source)
            #expect(!FileOperations.sameVolume(source, directory))
            try FileOperations.moveItem(source, to: destination)
            #expect(!FileOperations.exists(source) && FileOperations.exists(destination))
            let undo = FileUndo()
            undo.record(.moved([(source, destination)]), name: "Move")
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
            #expect(undo.undo() != nil)
            #expect(undo.canUndo && undo.canRedo)
            #expect(try String(contentsOf: source, encoding: .utf8) == "complete copy")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "complete copy")
            // Redo knows about the newly created inverse copy; it does not try a conflicting move.
            #expect(undo.redo() == nil)
            #expect(!FileOperations.exists(source) && FileOperations.exists(destination))
            #expect(undo.undo() == nil)
            #expect(FileOperations.exists(source) && FileOperations.exists(destination))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
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
            #expect(redo.undo() == nil)
            #expect(FileOperations.exists(source) && !FileOperations.exists(destination))
        }
    }

    @Test func volumeWithoutExclusiveRenameSupportsCopyMoveAndBulkRollback() throws {
        try withVolume("MS-DOS") { root, volume in
            let fm = FileManager.default
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
