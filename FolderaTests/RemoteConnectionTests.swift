import Citadel
import Foundation
import Testing
@testable import Foldera

@MainActor
struct RemoteConnectionsTests {
    @Test func connectionsAreSharedReusedAndReconnected() async throws {
        let endpoint = uniqueEndpoint()
        var made: [FakeRemoteFileSystem] = []
        let connections = RemoteConnections { _ in
            try await Task.sleep(for: .milliseconds(50))
            let system = FakeRemoteFileSystem()
            made.append(system)
            return system
        }
        async let first = connections.fileSystem(for: endpoint)
        async let second = connections.fileSystem(for: endpoint)
        let (a, b) = try await (first, second)
        #expect(a === b && made.count == 1, "concurrent callers share one sign-in")
        #expect(connections.connected == [endpoint])
        #expect(try await connections.fileSystem(for: endpoint) === a)

        made[0].disconnect()
        let reconnected = try await connections.fileSystem(for: endpoint)
        #expect(reconnected !== a && made.count == 2)

        // A read that fails because the connection dropped runs again on a new one.
        let dropped = made[1]
        let result = try await connections.read(endpoint) { system -> String in
            if system === dropped {
                dropped.disconnect()
                throw RemoteError.failed("dropped")
            }
            return "ok"
        }
        #expect(result == "ok" && made.count == 3)
        await #expect(throws: RemoteError.failed("real")) {
            try await connections.read(endpoint) { _ in throw RemoteError.failed("real") }
        }
        #expect(made.count == 3, "errors on a live connection don't reconnect")

        // A change is never replayed: it may have happened before the connection dropped.
        var runs = 0
        let change = made[2]
        await #expect(throws: RemoteError.failed("dropped")) {
            try await connections.perform(endpoint) { _ in
                runs += 1
                change.disconnect()
                throw RemoteError.failed("dropped")
            }
        }
        #expect(runs == 1 && connections.connected.isEmpty, "the dead connection is dropped, not retried")
        #expect(try await connections.perform(endpoint) { _ in "next" } == "next" && made.count == 4)

        await connections.disconnect(endpoint)
        #expect(connections.connected.isEmpty && made[3].operations.last == "close")
        connections.install(FakeRemoteFileSystem(), for: endpoint)
        #expect(connections.connected == [endpoint])
    }

    /// Staging and backup items are deleted by name, so a name someone else's item already has is never used.
    @Test func hiddenNamesAlreadyInUseAreNeverTakenOrDeleted() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), local = try TestDirectory()
        let target = try directory.file("data.txt", contents: "original")
        let part = try directory.file(".foldera-TAKEN.part/payload", contents: "someone else's upload")
        let old = try directory.file(".foldera-TAKEN.old/payload", contents: "someone else's backup")
        let edit = try local.file("data.txt", contents: "edited")
        let connections = RemoteConnections(connector: { _ in FakeRemoteFileSystem() }, journal: SwapJournal(defaults: nil))
        var tokens = ["TAKEN", "FIRST", "TAKEN", "SECOND"]
        connections.uniqueToken = { tokens.removeFirst() }
        func untouched() throws -> Bool {
            try String(contentsOf: part, encoding: .utf8) == "someone else's upload"
                && String(contentsOf: old, encoding: .utf8) == "someone else's backup"
        }

        try await connections.upload(edit, replacing: target.path, on: endpoint) { _ in }
        #expect(tokens.isEmpty && connections.journal.swaps.isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == "edited" && untouched())
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).count == 3)

        // A name that stays taken fails the replace instead.
        connections.uniqueToken = { "TAKEN" }
        await #expect(throws: RemoteError.alreadyExists("data.txt")) {
            try await connections.upload(edit, replacing: target.path, on: endpoint) { _ in }
        }
        #expect(try untouched())
    }

    /// Another client wins the name just as mkdir reaches the server. Failure never grants cleanup rights.
    @Test(arguments: ["part", "old"])
    func racingReservationsNeverDeleteSomeoneElsesItems(suffix: String) async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), local = try TestDirectory()
        let target = try directory.file("data.txt", contents: "original")
        let edit = try local.file("data.txt", contents: "edited")
        let occupied = directory.path(".foldera-TAKEN.\(suffix)")
        let payload = occupied.appendingPathComponent("payload")
        let server = FakeRemoteFileSystem(beforeMakeDirectory: { path in
            if path == occupied.path, !FileOperations.exists(occupied) {
                try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
                try Data("other client's data".utf8).write(to: payload)
            }
        })
        let connections = RemoteConnections(connector: { _ in server }, journal: SwapJournal(defaults: nil))
        connections.uniqueToken = { "TAKEN" }
        await #expect(throws: RemoteError.alreadyExists("data.txt")) {
            try await connections.upload(edit, replacing: target.path, on: endpoint) { _ in }
        }
        #expect(try String(contentsOf: payload, encoding: .utf8) == "other client's data")
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(connections.journal.swaps.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == [occupied.lastPathComponent, "data.txt"])
    }

    @Test func anUnacknowledgedReservationIsNeverClaimedOrCleanedUp() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), local = try TestDirectory()
        let target = try directory.file("data.txt", contents: "original")
        let edit = try local.file("data.txt", contents: "edited")
        let server = FakeRemoteFileSystem()
        server.simulateConnectionDrop("makeDirectory", applied: true)
        let connections = RemoteConnections(connector: { _ in server.reconnect() }, journal: SwapJournal(defaults: nil))
        var tokens = ["LOST", "FRESH", "BACKUP"]
        connections.uniqueToken = { tokens.removeFirst() }
        try await connections.upload(edit, replacing: target.path, on: endpoint) { _ in }
        let unknown = directory.path(".foldera-LOST.part")
        #expect(FileOperations.exists(unknown))
        #expect(try FileManager.default.contentsOfDirectory(atPath: unknown.path).isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == "edited")
        #expect(connections.journal.swaps.isEmpty && tokens.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == [unknown.lastPathComponent, "data.txt"])
    }

    @Test func privateSwapDirectoriesAreRecoveredAfterRelaunch() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), local = try TestDirectory()
        let preferences = try TestPreferences()
        let target = try directory.file("data.txt", contents: "original")
        let edit = try local.file("data.txt", contents: "edited")
        let server = FakeRemoteFileSystem()
        let first = RemoteConnections(connector: { _ in throw RemoteError.notConnected(endpoint.displayName) },
                                      journal: SwapJournal(defaults: preferences.defaults))
        first.install(server, for: endpoint)
        server.simulateConnectionDrop("rename", afterCalls: 1, applied: false)
        await #expect(throws: RemoteError.self) {
            try await first.upload(edit, replacing: target.path, on: endpoint) { _ in }
        }
        let reopened = SwapJournal(defaults: preferences.defaults)
        let pending = try #require(reopened.swaps.first)
        #expect(pending.backupDirectory != nil && pending.stagingDirectory != nil)
        #expect(pending.source == pending.staging)
        #expect(try String(contentsOfFile: pending.backup, encoding: .utf8) == "original")
        #expect(!FileOperations.exists(target))

        let restored = RemoteConnections(connector: { _ in server.reconnect() }, journal: reopened)
        _ = try await restored.fileSystem(for: endpoint)
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["data.txt"])
        #expect(SwapJournal(defaults: preferences.defaults).swaps.isEmpty)
    }

    @Test(arguments: [false, true])
    func concurrentCallersWaitForSwapSettlement(duringLogin: Bool) async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory()
        let path = directory.path("data.txt")
        let backup = try directory.file(".data.old", contents: "original")
        let journal = SwapJournal(defaults: nil)
        journal.add(PendingSwap(endpoint: endpoint, path: path.path, backup: backup.path, staging: nil))
        let loginStarted = ConnectionTestGate(), finishLogin = ConnectionTestGate()
        let settlementStarted = ConnectionTestGate(), finishSettlement = ConnectionTestGate()
        let system = FakeRemoteFileSystem(beforeList: {
            await settlementStarted.open()
            await finishSettlement.wait()
        })
        var attempts = 0
        let connections = RemoteConnections(connector: { _ in
            attempts += 1
            await loginStarted.open()
            await finishLogin.wait()
            return system
        }, journal: journal)
        let first = Task { try await connections.fileSystem(for: endpoint) }
        await loginStarted.wait()
        if !duringLogin {
            await finishLogin.open()
            await settlementStarted.wait()
        }
        var requested = false, mutations = 0, recoveredBeforeMutation = false
        let second = Task {
            requested = true
            try await connections.perform(endpoint) { filesystem in
                mutations += 1
                recoveredBeforeMutation = journal.swaps.isEmpty
                // A caller that sees the absent destination can create it and cause the backup to be discarded.
                if try await filesystem.entry(at: path.path) == nil { try await filesystem.createFile(path.path) }
            }
        }
        try await eventually { requested }
        await finishLogin.open()
        await settlementStarted.wait()
        try await Task.sleep(for: .milliseconds(50))
        #expect(mutations == 0, "no caller may use a connection before recovery finishes")
        await finishSettlement.open()
        #expect(try await first.value === system)
        try await second.value
        #expect(attempts == 1 && mutations == 1 && recoveredBeforeMutation)
        #expect(journal.swaps.isEmpty && !FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: path, encoding: .utf8) == "original")
    }

    @Test(arguments: [false, true])
    func legacyJournalsKeepAmbiguousBackups(hasStaging: Bool) async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        let target = try directory.file("data.txt", contents: "other client's data")
        let backup = try directory.file(".data.old", contents: "original")
        let staging = hasStaging ? try directory.file(".data.part", contents: "replacement") : nil
        let swap = PendingSwap(endpoint: endpoint, path: target.path, backup: backup.path, staging: staging?.path)
        SwapJournal(defaults: preferences.defaults).add(swap)
        let reopened = SwapJournal(defaults: preferences.defaults)
        #expect(reopened.swaps == [swap] && reopened.swaps.first?.source == nil)
        let connections = RemoteConnections(connector: { _ in FakeRemoteFileSystem() }, journal: reopened)
        await #expect(throws: RemoteError.replacementConflict(target.path, backup.path)) {
            _ = try await connections.fileSystem(for: endpoint)
        }
        #expect(try String(contentsOf: backup, encoding: .utf8) == "original")
        #expect(try String(contentsOf: target, encoding: .utf8) == "other client's data")
        if let staging { #expect(try String(contentsOf: staging, encoding: .utf8) == "replacement") }
        #expect(SwapJournal(defaults: preferences.defaults).swaps == [swap])

        try FileManager.default.removeItem(at: target)
        _ = try await connections.fileSystem(for: endpoint)
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["data.txt"])
        #expect(SwapJournal(defaults: preferences.defaults).swaps.isEmpty)
    }

    @Test func legacyUploadsUseTheirStagingPathToConfirmCommit() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        let target = try directory.file("data.txt", contents: "replacement")
        let backup = try directory.file(".data.old", contents: "original")
        SwapJournal(defaults: preferences.defaults).add(PendingSwap(endpoint: endpoint, path: target.path,
            backup: backup.path, staging: directory.path(".data.part").path))
        let reopened = SwapJournal(defaults: preferences.defaults)
        let connections = RemoteConnections(connector: { _ in FakeRemoteFileSystem() }, journal: reopened)
        _ = try await connections.fileSystem(for: endpoint)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["data.txt"])
        #expect(SwapJournal(defaults: preferences.defaults).swaps.isEmpty)
    }

    @Test func aSourceInsideTheReplacedDirectoryIsNeverMovedAside() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory()
        let source = try directory.file("data.txt/data.txt", contents: "replacement")
        try directory.file("data.txt/original.txt", contents: "original")
        let server = FakeRemoteFileSystem()
        let connections = RemoteConnections(connector: { _ in server }, journal: SwapJournal(defaults: nil))
        await #expect(throws: RemoteError.self) {
            try await connections.commit(source.path, to: source.deletingLastPathComponent().path,
                                         on: endpoint, replacing: true, isStaging: false)
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "replacement")
        #expect(try String(contentsOf: directory.path("data.txt/original.txt"), encoding: .utf8) == "original")
        #expect(server.operations.isEmpty && connections.journal.swaps.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["data.txt"])
    }

    @Test(arguments: [false, true])
    func aConnectionDroppedBySwapSettlementIsReconnectedBeforeAMutation(restore: Bool) async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory()
        let path = directory.path("data.txt")
        if !restore { try directory.file("data.txt", contents: "new") }
        let backup = try directory.file(".data.old", contents: "old")
        let journal = SwapJournal(defaults: nil)
        journal.add(PendingSwap(endpoint: endpoint, path: path.path, backup: backup.path, staging: nil,
                               source: directory.path("replacement.txt").path))
        let dropped = FakeRemoteFileSystem(), replacement = FakeRemoteFileSystem()
        dropped.simulateConnectionDrop(restore ? "rename" : "removeFile", applied: false)
        var attempts = 0
        let connections = RemoteConnections(connector: { _ in
            attempts += 1
            return attempts == 1 ? dropped : replacement
        }, journal: journal)
        var mutations = 0

        try await connections.perform(endpoint) { system in
            mutations += 1
            try await system.createFile(directory.path("created.txt").path)
        }
        #expect(attempts == 2 && mutations == 1)
        #expect(!dropped.operations.contains("createFile") && replacement.operations.contains("createFile"))
        #expect(try await connections.fileSystem(for: endpoint) === replacement)
        #expect(connections.connected == [endpoint] && FileManager.default.fileExists(atPath: directory.path("created.txt").path))
        #expect(journal.swaps.isEmpty && !FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: path, encoding: .utf8) == (restore ? "old" : "new"))
    }

    @Test func liveConnectionsSettleNewJournalWorkBeforeUse() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory()
        let path = directory.path("data.txt")
        let backup = try directory.file(".data.old", contents: "original")
        let journal = SwapJournal(defaults: nil)
        let system = FakeRemoteFileSystem()
        let connections = RemoteConnections(connector: { _ in throw RemoteError.failed("unexpected login") }, journal: journal)
        connections.install(system, for: endpoint)
        journal.add(PendingSwap(endpoint: endpoint, path: path.path, backup: backup.path, staging: nil))
        system.fail("rename", with: RemoteError.failed("permission"))
        var mutations = 0

        await #expect(throws: RemoteError.failed("permission")) {
            try await connections.perform(endpoint) { _ in mutations += 1 }
        }
        #expect(mutations == 0 && journal.swaps.count == 1)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "original")
        try await connections.perform(endpoint) { _ in
            mutations += 1
            #expect(journal.swaps.isEmpty)
            let contents = try String(contentsOf: path, encoding: .utf8)
            #expect(contents == "original")
        }
        #expect(mutations == 1 && !FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func repeatedRecoveryDropsKeepTheJournalAndBlockMutations() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory()
        let path = directory.path("data.txt")
        let backup = try directory.file(".data.old", contents: "original")
        let journal = SwapJournal(defaults: nil)
        journal.add(PendingSwap(endpoint: endpoint, path: path.path, backup: backup.path, staging: nil))
        let first = FakeRemoteFileSystem(), second = FakeRemoteFileSystem(), recovered = FakeRemoteFileSystem()
        first.simulateConnectionDrop("rename", applied: false)
        second.simulateConnectionDrop("rename", applied: false)
        var attempts = 0, mutations = 0
        let connections = RemoteConnections(connector: { _ in
            attempts += 1
            return attempts == 1 ? first : attempts == 2 ? second : recovered
        }, journal: journal)
        await #expect(throws: RemoteError.failed("connection lost")) {
            try await connections.perform(endpoint) { _ in mutations += 1 }
        }
        #expect(attempts == 2 && mutations == 0 && journal.swaps.count == 1)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "original")
        try await connections.perform(endpoint) { _ in
            mutations += 1
            #expect(journal.swaps.isEmpty)
            let contents = try String(contentsOf: path, encoding: .utf8)
            #expect(contents == "original")
        }
        #expect(attempts == 3 && mutations == 1)
    }

    @Test func activeSwapsAreNotSettledByConnectionAcquisition() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory()
        let path = directory.path("data.txt")
        let backup = try directory.file(".data.old", contents: "original")
        let journal = SwapJournal(defaults: nil)
        let swap = PendingSwap(endpoint: endpoint, path: path.path, backup: backup.path, staging: nil)
        journal.add(swap)
        let connections = RemoteConnections(connector: { _ in FakeRemoteFileSystem() }, journal: journal)
        connections.swapsInFlight.insert(swap)
        _ = try await connections.fileSystem(for: endpoint)
        #expect(journal.swaps == [swap] && !FileManager.default.fileExists(atPath: path.path))
        connections.swapsInFlight.remove(swap)
        _ = try await connections.fileSystem(for: endpoint)
        #expect(journal.swaps.isEmpty)
        #expect(try String(contentsOf: path, encoding: .utf8) == "original")
    }

    @Test func failedSignInsAreNotCached() async throws {
        let endpoint = uniqueEndpoint()
        var attempts = 0
        let connections = RemoteConnections { _ in
            attempts += 1
            if attempts == 1 { throw CancellationError() }
            return FakeRemoteFileSystem()
        }
        await #expect(throws: CancellationError.self) { _ = try await connections.fileSystem(for: endpoint) }
        #expect(connections.connected.isEmpty)
        _ = try await connections.fileSystem(for: endpoint)
        #expect(attempts == 2 && connections.connected == [endpoint])
    }

    @Test func disconnectingLeavesTheServerInEveryTab() async throws {
        let endpoint = uniqueEndpoint(), other = uniqueEndpoint()
        let connections = RemoteConnections { _ in FakeRemoteFileSystem() }
        let onServer = BrowserTab(url: endpoint.url(path: "/srv/data"))
        let elsewhere = BrowserTab(url: other.url(path: "/home"))
        await connections.disconnect(endpoint)
        for _ in 0..<50 where !onServer.isNetwork { try await Task.sleep(for: .milliseconds(10)) }
        #expect(onServer.isNetwork, "no stale server folder to click, which would sign in again")
        #expect(onServer.canGoBack)
        #expect(elsewhere.url.remoteEndpoint == other)
    }

    @Test func disconnectInvalidatesAnUnfinishedLogin() async throws {
        let endpoint = uniqueEndpoint(), started = ConnectionTestGate(), finish = ConnectionTestGate()
        let system = FakeRemoteFileSystem()
        var attempts = 0, requested = false, mutations = 0
        let connections = RemoteConnections { _ in
            attempts += 1
            await started.open()
            await finish.wait() // Deliberately ignores cancellation, like a delayed SSH login.
            return system
        }
        let first = Task { try await connections.fileSystem(for: endpoint) }
        await started.wait()
        let second = Task {
            requested = true
            try await connections.perform(endpoint) { _ in mutations += 1 }
        }
        try await eventually { requested }
        await connections.disconnect(endpoint)
        await finish.open()

        await #expect(throws: CancellationError.self) { _ = try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(attempts == 1 && mutations == 0 && connections.connected.isEmpty)
        #expect(!system.isConnected && system.operations == ["close"], "late connections must be closed, not published")
    }

    @Test func disconnectDuringRecoveryKeepsTheJournalAndDoesNotReconnect() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory()
        let path = directory.path("data.txt"), backup = try directory.file(".data.old", contents: "original")
        let journal = SwapJournal(defaults: nil)
        journal.add(PendingSwap(endpoint: endpoint, path: path.path, backup: backup.path, staging: nil))
        let started = ConnectionTestGate(), finish = ConnectionTestGate()
        let system = FakeRemoteFileSystem(beforeList: {
            await started.open()
            await finish.wait()
        })
        let replacement = FakeRemoteFileSystem()
        var attempts = 0, mutations = 0
        let connections = RemoteConnections(connector: { _ in
            attempts += 1
            return attempts == 1 ? system : replacement
        }, journal: journal)
        let operation = Task { try await connections.perform(endpoint) { _ in mutations += 1 } }
        await started.wait()
        await connections.disconnect(endpoint)
        await finish.open()

        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(attempts == 1 && mutations == 0 && connections.connected.isEmpty)
        #expect(journal.swaps.count == 1 && !FileManager.default.fileExists(atPath: path.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "original")
        try await connections.perform(endpoint) { _ in mutations += 1 }
        #expect(attempts == 2 && mutations == 1 && journal.swaps.isEmpty)
        #expect(try String(contentsOf: path, encoding: .utf8) == "original")
    }

    @Test(arguments: [false, true])
    func staleReadinessDoesNotClearANewerAttempt(failing: Bool) async throws {
        let endpoint = uniqueEndpoint()
        let oldStarted = ConnectionTestGate(), finishOld = ConnectionTestGate()
        let finishNew = ConnectionTestGate()
        let old = FakeRemoteFileSystem(), current = FakeRemoteFileSystem()
        var attempts = 0, replacementRequested = false, requested = false
        let connections = RemoteConnections { _ in
            attempts += 1
            if attempts == 1 {
                await oldStarted.open()
                await finishOld.wait()
                if failing { throw RemoteError.failed("stale login failed") }
                return old
            }
            await finishNew.wait()
            return current
        }
        let first = Task { try await connections.fileSystem(for: endpoint) }
        await oldStarted.wait()
        await connections.disconnect(endpoint)
        let second = Task {
            replacementRequested = true
            return try await connections.fileSystem(for: endpoint)
        }
        try await eventually { replacementRequested }
        try await Task.sleep(for: .milliseconds(50))
        #expect(attempts == 2, "disconnect allows a fresh login without waiting for the cancelled connector")
        await finishOld.open()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        let third = Task {
            requested = true
            return try await connections.fileSystem(for: endpoint)
        }
        try await eventually { requested }
        try await Task.sleep(for: .milliseconds(50))
        #expect(attempts == 2, "finishing an invalidated attempt must not erase the replacement's shared task")
        await finishNew.open()
        #expect((try? await second.value) === current)
        #expect((try? await third.value) === current)
        #expect(connections.connected == [endpoint] && current.isConnected)
        if !failing { #expect(!old.isConnected && old.operations == ["close"]) }
        #expect(try await connections.fileSystem(for: endpoint) === current && attempts == 2)
    }

    @Test(arguments: [false, true], [false, true])
    func disconnectedOperationsCannotRetryOrDropAReplacement(reading: Bool, replacing: Bool) async throws {
        let endpoint = uniqueEndpoint(), started = ConnectionTestGate(), finish = ConnectionTestGate()
        let old = FakeRemoteFileSystem(), current = FakeRemoteFileSystem()
        var attempts = 0
        let connections = RemoteConnections { _ in
            attempts += 1
            return current
        }
        connections.install(old, for: endpoint)
        let body: (any RemoteFileSystem) async throws -> Void = { _ in
            await started.open()
            await finish.wait()
            throw RemoteError.failed("old operation failed")
        }
        let operation = Task {
            if reading { try await connections.read(endpoint, body) }
            else { try await connections.perform(endpoint, body) }
        }
        await started.wait()
        await connections.disconnect(endpoint)
        if replacing { connections.install(current, for: endpoint) }
        await finish.open()

        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(attempts == 0, "a read that was explicitly disconnected must not log in again")
        #expect(connections.connected == (replacing ? [endpoint] : []))
        if replacing { #expect(try await connections.fileSystem(for: endpoint) === current && attempts == 0) }
    }

    @Test func installingAConnectionInvalidatesAnUnfinishedLogin() async throws {
        let endpoint = uniqueEndpoint(), started = ConnectionTestGate(), finish = ConnectionTestGate()
        let old = FakeRemoteFileSystem(), installed = FakeRemoteFileSystem()
        let connections = RemoteConnections { _ in
            await started.open()
            await finish.wait()
            return old
        }
        let attempt = Task { try await connections.fileSystem(for: endpoint) }
        await started.wait()
        connections.install(installed, for: endpoint)
        await finish.open()

        await #expect(throws: CancellationError.self) { _ = try await attempt.value }
        #expect(!old.isConnected && old.operations == ["close"])
        #expect(try await connections.fileSystem(for: endpoint) === installed && installed.isConnected)
        #expect(connections.connected == [endpoint])
    }

    @Test(arguments: [false, true])
    func lateFailuresDoNotEvictAnAutomaticReconnect(reading: Bool) async throws {
        let endpoint = uniqueEndpoint(), started = ConnectionTestGate(), finish = ConnectionTestGate()
        let old = FakeRemoteFileSystem(), current = FakeRemoteFileSystem()
        var attempts = 0, calls = 0
        let connections = RemoteConnections { _ in
            attempts += 1
            return current
        }
        connections.install(old, for: endpoint)
        let body: (any RemoteFileSystem) async throws -> String = { system in
            calls += 1
            if system === old {
                await started.open()
                await finish.wait()
                throw RemoteError.failed("old connection lost")
            }
            return "current"
        }
        let operation = Task {
            if reading { return try await connections.read(endpoint, body) }
            return try await connections.perform(endpoint, body)
        }
        await started.wait()
        old.disconnect()
        #expect(try await connections.fileSystem(for: endpoint) === current)
        await finish.open()

        if reading { #expect(try await operation.value == "current" && calls == 2) }
        else {
            await #expect(throws: RemoteError.failed("old connection lost")) { _ = try await operation.value }
            #expect(calls == 1, "mutations are still never replayed")
        }
        #expect(connections.connected == [endpoint])
        #expect(try await connections.fileSystem(for: endpoint) === current && attempts == 1)
    }
}

private actor ConnectionTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor
struct SFTPLoginTests {
    private func login(_ sites: SFTPSites, results: [Result<Void, Error>], asked: @escaping @MainActor (SFTPLogin.Prompt) -> SFTPLogin.Answer?) -> (SFTPLogin, () -> [SFTPCredentials]) {
        var tried: [SFTPCredentials] = []
        var remaining = results
        var login = SFTPLogin(sites: sites, hostKeys: SFTPHostKeys(defaults: sites.defaultsForTests))
        login.ask = asked
        login.connect = { _, credentials, _ in
            tried.append(credentials)
            if case .failure(let error) = remaining.removeFirst() { throw error }
            return FakeRemoteFileSystem()
        }
        return (login, { tried })
    }

    @Test func savedPasswordsAreUsedAndWrongOnesAskedAgain() async throws {
        let preferences = try TestPreferences()
        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        var site = SFTPSite()
        site.host = "h"; site.username = "u"
        sites.save(site, password: "old")
        var prompts: [SFTPLogin.Prompt] = []
        let denied = RemoteError.authenticationFailed(site.endpoint.displayName)
        let (login, tried) = login(sites, results: [.failure(denied), .success(())]) { prompt in
            prompts.append(prompt)
            return SFTPLogin.Answer(secret: "new", remember: true)
        }
        _ = try await login.connect(site.endpoint)
        #expect(prompts == [.password(site.endpoint, retry: true)])
        #expect(tried().compactMap { if case .password(let p) = $0 { p } else { nil } } == ["old", "new"])
        #expect(sites.password(for: site) == "new")
    }

    @Test func unsavedServersAskAndGiveUpAfterThreeTries() async throws {
        let preferences = try TestPreferences()
        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        let endpoint = uniqueEndpoint()
        let denied = RemoteError.authenticationFailed(endpoint.displayName)
        var prompts = 0
        let (login, tried) = login(sites, results: [.failure(denied), .failure(denied), .failure(denied)]) { _ in
            prompts += 1
            return SFTPLogin.Answer(secret: "p\(prompts)", remember: true)
        }
        await #expect(throws: denied) { _ = try await login.connect(endpoint) }
        #expect(prompts == 3 && tried().count == 3)

        let (cancelled, _) = self.login(sites, results: []) { _ in nil }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.connect(endpoint) }
    }

    @Test func keysAskForTheirPassphrase() async throws {
        let preferences = try TestPreferences(), directory = try TestDirectory()
        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        var site = SFTPSite()
        site.host = "h"; site.username = "u"; site.authentication = .privateKey
        site.keyPath = directory.path("missing").path
        sites.save(site)
        let (missing, _) = login(sites, results: []) { _ in nil }
        await #expect(throws: RemoteError.self) { _ = try await missing.connect(site.endpoint) }

        site.keyPath = try directory.file("id_ed25519", contents: "key").path
        sites.save(site)
        var prompts: [SFTPLogin.Prompt] = []
        let (login, tried) = login(sites, results: [.failure(SFTPFileSystem.KeyNeedsPassphrase()), .failure(RemoteError.unsupportedKey(site.keyPath)), .success(())]) { prompt in
            prompts.append(prompt)
            return SFTPLogin.Answer(secret: "phrase\(prompts.count)", remember: true)
        }
        _ = try await login.connect(site.endpoint)
        #expect(prompts == [.passphrase(path: site.keyPath, retry: false), .passphrase(path: site.keyPath, retry: true)])
        #expect(tried().compactMap { if case .privateKey(_, _, let phrase) = $0 { phrase } else { nil } } == [nil, "phrase1", "phrase2"])
        #expect(sites.passphrase(for: site) == "phrase2")
    }

    @Test func signsInToARealServerWithASavedKeySite() async throws {
        let server = try LocalSSHServer(), preferences = try TestPreferences()
        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        var site = SFTPSite()
        site.host = "127.0.0.1"; site.port = server.port; site.username = NSUserName()
        site.authentication = .privateKey
        site.keyPath = server.clientKey.path
        sites.save(site)
        let keys = SFTPHostKeys(defaults: preferences.defaults)
        keys.ask = { _, _ in true }
        let system = try await SFTPLogin(sites: sites, hostKeys: keys).connect(site.endpoint)
        #expect(try await system.home() == RemotePath.normalize(NSHomeDirectory()))
        await system.close()
    }

    @Test func encryptedKeysNeedTheirPassphrase() async throws {
        let server = try LocalSSHServer()
        let encrypted = server.directory.path("encrypted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "sesame", "-f", encrypted.path]
        try process.run()
        process.waitUntilExit()
        try FileManager.default.removeItem(at: server.directory.path("authorized_keys"))
        try FileManager.default.copyItem(at: server.directory.path("encrypted.pub"), to: server.directory.path("authorized_keys"))
        let key = try Data(contentsOf: encrypted)
        await #expect(throws: SFTPFileSystem.KeyNeedsPassphrase.self) {
            _ = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(key, path: encrypted.path, passphrase: nil), hostKey: .acceptAnything())
        }
        let system = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(key, path: encrypted.path, passphrase: "sesame"), hostKey: .acceptAnything())
        #expect(await system.isConnected)
        await system.close()
    }
}

private extension SFTPSites {
    /// Host keys for login tests aren't checked (the connection is stubbed), so any defaults will do.
    var defaultsForTests: UserDefaults { UserDefaults(suiteName: "FolderaTests.hostKeys.\(UUID())")! }
}
