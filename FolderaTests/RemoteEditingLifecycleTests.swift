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

    @Test func repeatedAndOverlappingOpensShareOneEditingCopy() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let started = EditingTestGate(), release = EditingTestGate()
        let server = FakeRemoteFileSystem(beforeList: {
            await started.open()
            await release.wait()
        })
        let manager = editing(cache, server: server)
        let original = try remote.file("shared.txt", contents: "v1")
        let address = uniqueEndpoint().url(path: original.path)
        let first = Task { try await manager.open(address) }
        await started.wait()
        let second = Task { try await manager.open(address) }
        for _ in 0..<10 { await Task.yield() }
        await release.open()
        let local = try await first.value
        #expect(try await second.value == local)
        #expect(try await manager.open(address) == local)
        #expect(manager.sessions.count == 1)
        #expect(server.operations.filter { $0 == "download" }.count == 1)
        manager.prepareToQuit()
    }

    @Test func symbolicLinksAreNotOpenedForEditing() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let original = try remote.file("target.txt", contents: "KEEP")
        let link = remote.path("current.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let manager = editing(cache, server: FakeRemoteFileSystem())
        await #expect(throws: RemoteError.self) { try await manager.open(uniqueEndpoint().url(path: link.path)) }
        #expect(manager.sessions.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == original.path)
        #expect(try String(contentsOf: original, encoding: .utf8) == "KEEP")
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

    @Test func reopeningARecoveredFileResumesOnlyItsEditingCopy() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let server = FakeRemoteFileSystem(), endpoint = uniqueEndpoint()
        let manager = editing(cache, server: server)
        let original = try remote.file("page.txt", contents: "SERVER")
        let other = try remote.file("other.txt", contents: "OTHER")
        let address = endpoint.url(path: original.path)
        let local = try await manager.open(address)
        let otherLocal = try await manager.open(endpoint.url(path: other.path))
        try "UNSENT".write(to: local, atomically: true, encoding: .utf8)
        try "OTHER UNSENT".write(to: otherLocal, atomically: true, encoding: .utf8)
        manager.prepareToQuit()
        let restored = editing(cache, server: server)
        await restored.uploadNow()
        #expect(try String(contentsOf: original, encoding: .utf8) == "SERVER")
        let reopened = try await restored.open(address)
        #expect(reopened.normalizedFileURL == local.normalizedFileURL)
        #expect(try String(contentsOf: local, encoding: .utf8) == "UNSENT")
        #expect(restored.sessions.first { $0.remote == address }?.isRecovered == false)
        #expect(server.operations.filter { $0 == "download" }.count == 2)
        try "NEW SAVE".write(to: local, atomically: true, encoding: .utf8)
        await restored.finishEditing()
        #expect(try String(contentsOf: original, encoding: .utf8) == "NEW SAVE")
        #expect(try String(contentsOf: other, encoding: .utf8) == "OTHER")
        #expect(restored.sessions.map { $0.local.normalizedFileURL } == [otherLocal.normalizedFileURL] && restored.hasRecoveredSessions)
        #expect(try String(contentsOf: otherLocal, encoding: .utf8) == "OTHER UNSENT")
        restored.prepareToQuit()
    }

    /// Editors and tools can rewrite a file and set its modification date back. The bytes are still new, so
    /// they're uploaded, and the copy isn't deleted as if it were synchronized.
    @Test func rewritesThatKeepTheModificationDateAreStillUploaded() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let manager = editing(cache, server: FakeRemoteFileSystem())
        let original = try remote.file("notes.txt", contents: "v1")
        let local = try await manager.open(uniqueEndpoint().url(path: original.path))
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: local.path)[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: local) // in place: same file, same size
        try handle.write(contentsOf: Data("v2".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: local.path)
        #expect(manager.pendingFiles == ["notes.txt"])
        await manager.finishEditing()
        #expect(try String(contentsOf: original, encoding: .utf8) == "v2")
        #expect(manager.sessions.isEmpty)
    }

    /// Records written before versions included more than a date can't vouch for their copy: it's kept for recovery.
    @Test func olderRecordsKeepTheirCopiesForRecovery() async throws {
        let cache = try TestDirectory(), remote = try TestDirectory()
        let server = FakeRemoteFileSystem()
        var manager: RemoteEditing? = editing(cache, server: server)
        let original = try remote.file("old.txt", contents: "v1")
        let local = try #require(await manager?.open(uniqueEndpoint().url(path: original.path)))
        let session = try #require(manager?.sessions.first)
        let metadata = session.directory.appendingPathComponent("session.json")
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        record["uploadedVersion"] = Date().timeIntervalSinceReferenceDate
        record["closed"] = true
        try JSONSerialization.data(withJSONObject: record).write(to: metadata, options: .atomic)
        manager = nil // ended without cleaning up
        let restored = editing(cache, server: server)
        #expect(restored.hasRecoveredSessions && FileOperations.exists(local))
        restored.prepareToQuit()
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
        let other = try remote.file("other/saved.txt", contents: "v1")
        let endpoint = uniqueEndpoint()
        let unchanged = try #require(await manager?.open(endpoint.url(path: original.path)))
        let dirty = try #require(await manager?.open(endpoint.url(path: other.path)))
        try #require(unchanged != dirty)
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
