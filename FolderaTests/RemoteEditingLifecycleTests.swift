import AppKit
import Foundation
import Testing
@testable import Foldera

@MainActor
@Suite(.serialized)
struct RemoteEditingLifecycleTests {
    private func editing(_ cache: TestDirectory, server: FakeRemoteFileSystem) -> RemoteEditing {
        let connections = RemoteConnections(connector: { _ in server })
        return RemoteEditing(connections: connections, folder: cache.url, openFile: { _ in }, retryDelay: 60)
    }

    @Test func finishingUploadsTheLastSaveThenRemovesItsDirectory() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let server = FakeRemoteFileSystem()
        let manager = editing(cache, server: server)
        let original = try remote.file("session.json", contents: "v1")
        let local = try await manager.open(uniqueEndpoint().url(path: original.path))
        let session = try #require(manager.sessions.first)
        #expect((try FileManager.default.attributesOfItem(atPath: cache.url.path))[.posixPermissions] as? Int == 0o700)
        #expect(try cache.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect((try FileManager.default.attributesOfItem(atPath: session.directory.path))[.posixPermissions] as? Int == 0o700)
        try "v2".write(to: local, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: local.path)
        await manager.finishEditing()
        #expect(try String(contentsOf: original, encoding: .utf8) == "v2")
        #expect(manager.sessions.isEmpty && !FileOperations.exists(session.directory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.url.path).isEmpty)
    }

    @Test func normalQuitCleansSynchronizedCopies() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let manager = editing(cache, server: FakeRemoteFileSystem())
        let original = try remote.file("private.txt", contents: "SECRET")
        let local = try await manager.open(uniqueEndpoint().url(path: original.path))
        let delegate = FolderaAppDelegate()
        delegate.editing = manager
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!FileOperations.exists(local) && manager.sessions.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "SECRET")
    }

    @Test func finishingWaitsForAnUploadAlreadyInProgress() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let started = EditingTestGate(), release = EditingTestGate()
        let server = FakeRemoteFileSystem(beforeUpload: {
            await started.open()
            await release.wait()
        })
        let manager = editing(cache, server: server)
        let original = try remote.file("page.txt", contents: "v1")
        let local = try await manager.open(uniqueEndpoint().url(path: original.path))
        try "v2".write(to: local, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: local.path)
        let upload = Task { await manager.uploadChanges() }
        await started.wait()
        var finished = false
        let finish = Task { await manager.finishEditing(); finished = true }
        for _ in 0..<10 { await Task.yield() }
        #expect(manager.isUploading && !finished)
        manager.prepareToQuit()
        #expect(FileOperations.exists(local))
        await release.open()
        await upload.value
        await finish.value
        #expect(finished && manager.sessions.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "v2")
        #expect(!FileOperations.exists(local))
    }

    @Test func unsentChangesSurviveQuitAndWaitForExplicitRecovery() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let server = FakeRemoteFileSystem()
        let manager = editing(cache, server: server)
        let original = try remote.file("page.txt", contents: "v1")
        let local = try await manager.open(uniqueEndpoint().url(path: original.path))
        try "UNSENT".write(to: local, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: local.path)
        manager.prepareToQuit()
        let restored = editing(cache, server: server)
        #expect(restored.hasRecoveredSessions && restored.pendingFiles == ["page.txt"])
        await restored.uploadNow()
        restored.prepareToQuit()
        #expect(try String(contentsOf: original, encoding: .utf8) == "v1", "recovery must not automatically overwrite the server")
        #expect(try String(contentsOf: local, encoding: .utf8) == "UNSENT")
        restored.resumeRecoveredEdits()
        await restored.finishEditing()
        #expect(try String(contentsOf: original, encoding: .utf8) == "UNSENT")
        #expect(restored.sessions.isEmpty && !FileOperations.exists(local))
    }

    @Test func failedFinishRetainsTheOnlyUnsentCopy() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let server = FakeRemoteFileSystem(), errors = ErrorCollector()
        let manager = editing(cache, server: server)
        let original = try remote.file("pending.txt", contents: "v1")
        let local = try await manager.open(uniqueEndpoint().url(path: original.path))
        try "v2".write(to: local, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: local.path)
        server.fail("upload", with: RemoteError.failed("offline"))
        await manager.finishEditing()
        manager.prepareToQuit()
        #expect(try String(contentsOf: original, encoding: .utf8) == "v1")
        #expect(try String(contentsOf: local, encoding: .utf8) == "v2")
        #expect(manager.pendingFiles == ["pending.txt"] && errors.errors.count == 1)
        #expect(editing(cache, server: server).hasRecoveredSessions)
    }

    @Test func startupCleansOnlyClosedCopiesWhoseVersionStillMatches() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let server = FakeRemoteFileSystem()
        var manager: RemoteEditing? = editing(cache, server: server)
        let original = try remote.file("saved.txt", contents: "v1")
        let endpoint = uniqueEndpoint()
        let unchanged = try #require(await manager?.open(endpoint.url(path: original.path)))
        let dirty = try #require(await manager?.open(endpoint.url(path: original.path)))
        for session in manager?.sessions ?? [] {
            let metadata = session.directory.appendingPathComponent("session.json")
            var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            record["closed"] = true
            try JSONSerialization.data(withJSONObject: record).write(to: metadata, options: .atomic)
        }
        try "UNSENT".write(to: dirty, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: dirty.path)
        // Stop the first instance as if its process had ended without completing cleanup.
        manager = nil
        let restored = editing(cache, server: server)
        #expect(!FileOperations.exists(unchanged))
        #expect(try String(contentsOf: dirty, encoding: .utf8) == "UNSENT")
        #expect(restored.sessions.count == 1 && restored.pendingFiles == ["saved.txt"])
        restored.prepareToQuit()
    }

    @Test func untrackedFilesAndUnsafeRecoveryRecordsAreNotDeleted() throws {
        let cache = try TestDirectory(), outside = try TestDirectory()
        let original = try outside.file("keep.txt", contents: "KEEP")
        let legacy = try cache.file("legacy.txt", contents: "UNKNOWN UPLOAD STATE")
        let directory = try cache.folder(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("files"), withIntermediateDirectories: false)
        let record: [String: Any] = ["remote": "sftp://test@host/file", "name": "../../keep.txt", "closed": true]
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("session.json"))
        let restored = editing(cache, server: FakeRemoteFileSystem())
        restored.prepareToQuit()
        #expect(restored.sessions.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "KEEP")
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "UNKNOWN UPLOAD STATE")
        #expect(FileOperations.exists(directory))
    }
}

private actor EditingTestGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}
