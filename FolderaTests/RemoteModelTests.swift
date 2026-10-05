import Foundation
import Testing
@testable import Foldera

@MainActor
struct RemoteURLTests {
    @Test func endpointsRoundTripThroughURLs() throws {
        let endpoint = RemoteEndpoint(host: "Example.COM", port: 2222, username: "me")
        #expect(endpoint.host == "example.com" && endpoint.displayName == "me@example.com:2222" && endpoint.hostKeyID == "example.com:2222")
        let url = endpoint.url(path: "/srv/My Files/../data/./x y")
        #expect(url.absoluteString == "sftp://me@example.com:2222/srv/data/x%20y")
        #expect(url.isRemote && url.remotePath == "/srv/data/x y" && url.remoteEndpoint == endpoint)
        let standard = RemoteEndpoint(host: "h", username: "u")
        #expect(standard.root.absoluteString == "sftp://u@h/" && standard.displayName == "u@h")
        #expect(try #require(URL(string: "SFTP://u@h")).remoteEndpoint == standard)
        #expect(URL(string: "sftp://h/x")?.remoteEndpoint == nil, "a user name is required")
        #expect(URL(string: "smb://u@h/x")?.remoteEndpoint == nil)
        #expect(URL(fileURLWithPath: "/tmp").isRemote == false)
        #expect(try #require(URL(string: "sftp://u@h/a/b/")).normalizedFileURL == standard.url(path: "/a/b"))
        #expect(try #require(URL(string: "sftp://u@h")).remotePath == "/")
    }

    @Test func remotePathsNeverEscapeTheRoot() {
        #expect(RemotePath.normalize("") == "/")
        #expect(RemotePath.normalize("a//b/../c/.") == "/a/c")
        #expect(RemotePath.normalize("/../../etc") == "/etc")
        #expect(RemotePath.join("/a", "b") == "/a/b" && RemotePath.join("/", "..") == "/")
        #expect(RemotePath.parent(of: "/a/b") == "/a" && RemotePath.parent(of: "/") == "/")
        #expect(RemotePath.name(of: "/a/b/") == "b" && RemotePath.name(of: "/") == "/")
        #expect(RemotePath.isWithin("/a/b", "/a") && RemotePath.isWithin("/a", "/a") && RemotePath.isWithin("/x", "/"))
        #expect(!RemotePath.isWithin("/ab", "/a"))
    }

    @Test func remoteItemsBecomeFileItems() {
        let endpoint = RemoteEndpoint(host: "h", username: "u")
        let date = Date(timeIntervalSince1970: 100)
        let file = FileItem(remote: RemoteEntry(path: "/d/photo.jpg", isDirectory: false, isSymlink: false, size: 5, modified: date, permissions: 0o644), endpoint: endpoint)
        #expect(file.url == endpoint.url(path: "/d/photo.jpg") && file.name == "photo.jpg" && file.size == 5 && file.dateModified == date)
        #expect(!file.isNavigable && file.contentType == .jpeg && !file.kind.isEmpty && !file.isHidden)
        let folder = FileItem(remote: RemoteEntry(path: "/d/.config", isDirectory: true, isSymlink: true, size: 64, modified: nil, permissions: nil), endpoint: endpoint)
        #expect(folder.isNavigable && folder.size == nil && folder.isHidden && folder.kind == "Folder")
        let unknown = FileItem(remote: RemoteEntry(path: "/d/README", isDirectory: false, isSymlink: false, size: nil, modified: nil, permissions: nil), endpoint: endpoint)
        #expect(unknown.kind == "File")
    }

    @Test func errorsDescribeTheProblem() {
        #expect(RemoteError.notConnected("s").localizedDescription.contains("s"))
        #expect(RemoteError.authenticationFailed("s").localizedDescription.contains("s"))
        #expect(RemoteError.hostKeyRejected("s").localizedDescription.contains("s"))
        #expect(RemoteError.unsupportedKey("/k").localizedDescription.contains("/k"))
        #expect(RemoteError.notFound("n").localizedDescription.contains("n"))
        #expect(RemoteError.alreadyExists("n").localizedDescription.contains("n"))
        let conflict = RemoteError.replacementConflict("/destination", "/backup").localizedDescription
        #expect(conflict.contains("/destination") && conflict.contains("/backup"))
        #expect(RemoteError.failed("custom").localizedDescription == "custom")
    }
}

@MainActor
struct SFTPSitesTests {
    @Test func sitesPersistAndKeepSecretsOutOfDefaults() throws {
        let preferences = try TestPreferences(), secrets = MemorySecrets()
        let sites = SFTPSites(defaults: preferences.defaults, secrets: secrets)
        var site = SFTPSite()
        #expect(!site.isComplete && site.title == "@")
        site.host = " files.example.com "
        site.username = "me"
        #expect(site.isComplete && site.title == "me@files.example.com" && site.endpoint.host == "files.example.com")
        site.authentication = .privateKey
        #expect(!site.isComplete)
        site.keyPath = "~/.ssh/id_ed25519"
        #expect(site.isComplete && site.expandedKeyPath == NSHomeDirectory() + "/.ssh/id_ed25519")
        site.port = 70_000
        #expect(!site.isComplete)
        site.port = 22
        site.name = "Work"
        sites.save(site, password: "secret")
        #expect(sites.password(for: site) == "secret" && secrets.values.count == 1)
        sites.setPassphrase("phrase", for: site)
        let reloaded = SFTPSites(defaults: preferences.defaults, secrets: secrets)
        #expect(reloaded.sites == [site] && reloaded.site(for: site.endpoint)?.title == "Work")
        #expect(reloaded.passphrase(for: site) == "phrase")
        #expect(preferences.defaults.data(forKey: "sftpSites").map { String(decoding: $0, as: UTF8.self).contains("secret") } == false)

        site.name = "Renamed"
        sites.save(site)
        #expect(sites.sites.map(\.name) == ["Renamed"] && sites.password(for: site) == "secret")
        sites.save(site, password: "")
        #expect(sites.password(for: site) == nil)
        sites.remove(site)
        #expect(sites.sites.isEmpty && secrets.values.isEmpty)
        #expect(sites.site(for: site.endpoint) == nil)
    }

    @Test func keychainStoresReadsAndDeletesSecrets() {
        let keychain = KeychainSecrets(service: "Foldera Tests \(UUID())")
        let account = "password:\(UUID())"
        #expect(keychain.secret(for: account) == nil)
        keychain.setSecret("first", for: account)
        keychain.setSecret("second", for: account)
        #expect(keychain.secret(for: account) == "second")
        keychain.setSecret(nil, for: account)
        #expect(keychain.secret(for: account) == nil)
    }
}

@MainActor
struct SFTPHostKeysTests {
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOv6oVq8PZzq0Kq7mx4jE7VnS7hB5z1cJcSg3qSmQmXv test"

    @Test func trustsOnFirstUseAndWarnsWhenTheKeyChanges() throws {
        let preferences = try TestPreferences()
        let keys = SFTPHostKeys(defaults: preferences.defaults)
        let endpoint = RemoteEndpoint(host: "h", port: 2222, username: "u")
        var asked: [SFTPHostKeys.Check] = []
        var answer = false
        keys.ask = { check, _ in asked.append(check); return answer }

        let fingerprint = SFTPHostKeys.fingerprint(of: key)
        #expect(fingerprint.hasPrefix("SHA256:") && !fingerprint.hasSuffix("="))
        #expect(SFTPHostKeys.fingerprint(of: "garbage") == "garbage")
        #expect(keys.check(key, for: endpoint) == .unknown(fingerprint: fingerprint))
        #expect(!keys.accept(key, for: endpoint) && keys.trustedKey(for: endpoint) == nil)
        answer = true
        #expect(keys.accept(key, for: endpoint) && keys.trustedKey(for: endpoint) == key)
        #expect(keys.accept(key, for: endpoint) && asked.count == 2, "a trusted key isn't asked about again")
        #expect(keys.check(key, for: RemoteEndpoint(host: "h", port: 2222, username: "other")) == .trusted, "keys belong to the host, not the user")

        let other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBn3n2cDqvKe5sQd1gY7mI5yGm4Ylg9p7bVY0hQe1X2Q other"
        #expect(keys.check(other, for: endpoint) == .changed(fingerprint: SFTPHostKeys.fingerprint(of: other)))
        answer = false
        #expect(!keys.accept(other, for: endpoint) && keys.trustedKey(for: endpoint) == key)
        keys.forget(endpoint)
        #expect(keys.trustedKey(for: endpoint) == nil)
    }

    @Test func simultaneousChecksShareOnePrompt() async throws {
        let preferences = try TestPreferences()
        let keys = SFTPHostKeys(defaults: preferences.defaults)
        let endpoint = RemoteEndpoint(host: "h", username: "u")
        var asked = 0
        keys.ask = { _, _ in asked += 1; return true }
        async let first = keys.decide(key, for: endpoint)
        async let second = keys.decide(key, for: endpoint)
        let results = await [first, second]
        #expect(results == [true, true] && asked == 1)
        #expect(await keys.decide(key, for: endpoint) && asked == 1)
    }

    @Test func fingerprintsMatchOpenSSH() throws {
        let server = try LocalSSHServer()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-l", "-E", "sha256", "-f", server.directory.path("host.pub").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains(SFTPHostKeys.fingerprint(of: server.hostPublicKey)))
    }

    @Test func connectingAsksOnceThenTrustsTheServer() async throws {
        let server = try LocalSSHServer(), preferences = try TestPreferences()
        let keys = SFTPHostKeys(defaults: preferences.defaults)
        var asked = 0
        keys.ask = { _, _ in asked += 1; return asked > 1 }
        await #expect(throws: RemoteError.hostKeyRejected(server.endpoint.displayName)) {
            _ = try await SFTPFileSystem.connect(to: server.endpoint, credentials: try server.credentials, hostKey: keys.validator(for: server.endpoint))
        }
        let first = try await SFTPFileSystem.connect(to: server.endpoint, credentials: try server.credentials, hostKey: keys.validator(for: server.endpoint))
        await first.close()
        let second = try await SFTPFileSystem.connect(to: server.endpoint, credentials: try server.credentials, hostKey: keys.validator(for: server.endpoint))
        #expect(await second.isConnected)
        await second.close()
        #expect(asked == 2 && keys.trustedKey(for: server.endpoint) == server.hostPublicKey.split(separator: " ").prefix(2).joined(separator: " "))
    }
}
