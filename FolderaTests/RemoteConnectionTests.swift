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
