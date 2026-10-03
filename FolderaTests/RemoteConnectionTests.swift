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
    func aConnectionDroppedBySwapSettlementIsReconnectedBeforeAMutation(restore: Bool) async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory()
        let path = directory.path("data.txt")
        if !restore { try directory.file("data.txt", contents: "new") }
        let backup = try directory.file(".data.old", contents: "old")
        let journal = SwapJournal(defaults: nil)
        journal.add(PendingSwap(endpoint: endpoint, path: path.path, backup: backup.path, staging: nil))
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
