import Foundation
import NIOSSH
import Testing
@testable import Foldera

/// Real SFTP against a local OpenSSH server.
@Suite(.serialized)
struct SFTPFileSystemTests {
    @Test func downloadsRejectOccupiedPathsWithoutRemovingThem() async throws {
        let server = try LocalSSHServer(), directory = try TestDirectory()
        let sftp = try await server.connect()
        let source = try directory.file("remote", contents: "REMOTE")
        let existing = try directory.file("existing", contents: "KEEP")
        let folder = try directory.folder("occupied")
        try Data("KEEP DIRECTORY".utf8).write(to: folder.appendingPathComponent("keep"))
        let target = directory.path("missing"), link = directory.path("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        for destination in [existing, folder, link] {
            await #expect(throws: POSIXError(.EEXIST)) {
                try await sftp.download(source.path, to: destination) { _ in }
            }
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "KEEP")
        #expect(try String(contentsOf: folder.appendingPathComponent("keep"), encoding: .utf8) == "KEEP DIRECTORY")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(!FileOperations.exists(target))
        await sftp.close()
    }

    @Test func cancelledDownloadRemovesOnlyTheFileItCreated() async throws {
        let server = try LocalSSHServer(), directory = try TestDirectory()
        let sftp = try await server.connect()
        let source = try directory.file("remote", contents: String(repeating: "R", count: 100_000))
        let cancelled = directory.path("cancelled")
        await #expect(throws: CopyEngine.Cancelled.self) {
            try await sftp.download(source.path, to: cancelled) { _ in throw CopyEngine.Cancelled() }
        }
        #expect(!FileOperations.exists(cancelled))
        let racing = directory.path("racing"), moved = directory.path("moved")
        await #expect(throws: CopyEngine.Cancelled.self) {
            try await sftp.download(source.path, to: racing) { _ in
                try FileManager.default.moveItem(at: racing, to: moved)
                try Data("RACER".utf8).write(to: racing)
                throw CopyEngine.Cancelled()
            }
        }
        #expect(try String(contentsOf: racing, encoding: .utf8) == "RACER")
        #expect(try Data(contentsOf: moved).count > 0)
        await sftp.close()
    }

    @Test func browsesTransfersRenamesAndDeletesOverSFTP() async throws {
        let server = try LocalSSHServer()
        let local = try TestDirectory()
        let sftp = try await server.connect()
        #expect(await sftp.isConnected)
        #expect(try await sftp.home() == RemotePath.normalize(NSHomeDirectory()))

        let root = local.url.path
        let folder = RemotePath.join(root, "remote folder")
        try await sftp.makeDirectory(folder)
        let source = try local.file("upload.txt", contents: String(repeating: "Foldera ", count: 40_000))
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        let remoteFile = RemotePath.join(folder, "upload.txt")
        let uploaded = Counter()
        try await sftp.upload(source, to: remoteFile) { uploaded.add($0) }
        #expect(uploaded.value == 320_000)

        let listing = try await sftp.list(folder)
        #expect(listing.map(\.name) == ["upload.txt"])
        #expect(listing[0].size == 320_000 && !listing[0].isDirectory && listing[0].modified == modified)
        try FileManager.default.createSymbolicLink(atPath: RemotePath.join(root, "link"), withDestinationPath: folder)
        let link = try #require(try await sftp.list(root).first { $0.name == "link" })
        #expect(link.isSymlink && link.isDirectory)

        let downloaded = local.path("downloaded.txt")
        let received = Counter()
        try await sftp.download(remoteFile, to: downloaded) { received.add($0) }
        #expect(try Data(contentsOf: downloaded) == Data(contentsOf: source) && received.value == 320_000)
        #expect((try downloaded.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate == modified)

        let replacement = try local.file("replacement.txt", contents: "new contents")
        let connections = RemoteConnections { _ in throw RemoteError.notConnected("") }
        connections.install(sftp, for: server.endpoint)
        try await connections.upload(replacement, replacing: remoteFile, on: server.endpoint) { _ in }
        #expect(try String(contentsOfFile: remoteFile, encoding: .utf8) == "new contents")
        #expect(try await sftp.list(folder).map(\.name) == ["upload.txt"], "the staging file was renamed into place")
        try await sftp.upload(source, to: remoteFile) { _ in }

        let renamed = RemotePath.join(folder, "renamed.txt")
        try await sftp.rename(remoteFile, to: renamed)
        #expect(try await sftp.entry(at: remoteFile) == nil)
        #expect(try await sftp.entry(at: renamed)?.size == 320_000)
        try await sftp.createFile(RemotePath.join(folder, "empty.txt"))
        #expect(try await sftp.uniquePath(named: "empty.txt", in: folder) == RemotePath.join(folder, "empty (2).txt"))
        #expect(try await sftp.totalSize(try #require(try await sftp.entry(at: folder))) == 320_000)

        try await sftp.removeRecursively(link)
        #expect(FileManager.default.fileExists(atPath: folder), "deleting a link must not follow it")
        try await sftp.removeRecursively(try #require(try await sftp.entry(at: folder)))
        #expect(!FileManager.default.fileExists(atPath: folder))
        await #expect(throws: RemoteError.notFound("missing")) { try await sftp.list(RemotePath.join(root, "missing")) }
        await sftp.close()
    }

    @Test func pipelinedTransfersKeepEveryByteInOrder() async throws {
        let server = try LocalSSHServer(), local = try TestDirectory()
        let sftp = try await server.connect()
        let size = 5 * 1024 * 1024 + 12_345
        let source = local.path("source.bin")
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }).write(to: source)
        let remote = RemotePath.join(local.url.path, "remote.bin"), back = local.path("back.bin")
        try await sftp.upload(source, to: remote) { _ in }
        try await sftp.download(remote, to: back) { _ in }
        #expect(try Data(contentsOf: back) == Data(contentsOf: source))
        await sftp.close()
    }

    @Test(arguments: [
        ("rsa-pkcs1", ["-t", "rsa", "-m", "PEM"], "-----BEGIN RSA PRIVATE KEY-----"),
        ("rsa-pkcs8", ["-t", "rsa", "-m", "PKCS8"], "-----BEGIN PRIVATE KEY-----"),
        ("ecdsa-sec1", ["-t", "ecdsa", "-b", "256", "-m", "PEM"], "-----BEGIN EC PRIVATE KEY-----"),
        ("ecdsa-pkcs8", ["-t", "ecdsa", "-b", "384", "-m", "PKCS8"], "-----BEGIN PRIVATE KEY-----"),
        ("ecdsa-openssh", ["-t", "ecdsa", "-b", "521"], "-----BEGIN OPENSSH PRIVATE KEY-----"),
        ("rsa-openssh", ["-t", "rsa"], "-----BEGIN OPENSSH PRIVATE KEY-----"),
    ])
    func signsInWithUnencryptedKeysInEachFormat(name: String, options: [String], armor: String) async throws {
        let server = try LocalSSHServer()
        let key = try server.authorizeKey(name, options + ["-N", ""])
        // Saved with Windows line endings, as keys downloaded through a browser sometimes are.
        let text = try String(contentsOf: key, encoding: .utf8).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(text.hasPrefix(armor))
        let sftp = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(Data(text.utf8), path: key.path, passphrase: nil), hostKey: .acceptAnything())
        #expect(await sftp.isConnected)
        await sftp.close()
    }

    @Test func rsaKeysSendTheSSHRSABlobWithSHA2Algorithms() throws {
        let directory = try TestDirectory()
        let key = directory.path("rsa")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "rsa", "-m", "PEM", "-N", "", "-C", "foldera-tests", "-f", key.path]
        try keygen.run()
        keygen.waitUntilExit()
        let expectedBlob = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ")[1]
        let keys = try SSHPrivateKey.privateKeys(try String(contentsOf: key, encoding: .utf8), passphrase: nil)
        // RFC 8332: the algorithm names SHA-2, but the key blob is still "ssh-rsa", e, n, exactly as ssh-keygen writes it.
        let offered = keys.map { String(openSSHPublicKey: $0.publicKey).split(separator: " ") }
        #expect(offered.map { String($0[0]) } == ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"])
        #expect(offered.allSatisfy { $0[1] == expectedBlob })
    }

    @Test(arguments: ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"])
    func rsaKeysFallBackToWhicheverSignatureTheServerAccepts(algorithm: String) async throws {
        let server = try LocalSSHServer(extraConfig: "PubkeyAcceptedAlgorithms \(algorithm)")
        let key = try server.authorizeKey("rsa", ["-t", "rsa", "-N", ""])
        let sftp = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(try Data(contentsOf: key), path: key.path, passphrase: nil), hostKey: .acceptAnything())
        #expect(await sftp.isConnected)
        await sftp.close()
    }

    @Test func serversWithOnlyAnSSHRSAHostKeyStillConnectAfterRSALogins() async throws {
        // Like OpenSSH before 8.8. The SHA-2 RSA types must not be offered as host key algorithms: NIOSSH couldn't
        // read such a host key back. (Citadel verifies RSA host keys only as "ssh-rsa", as before.)
        let server = try LocalSSHServer(hostKeyType: "rsa", extraConfig: "HostKeyAlgorithms ssh-rsa")
        let key = try server.authorizeKey("rsa", ["-t", "rsa", "-N", ""])
        let credentials = [SFTPCredentials.privateKey(try Data(contentsOf: key), path: key.path, passphrase: nil), try server.credentials]
        for credential in credentials {
            let sftp = try await SFTPFileSystem.connect(to: server.endpoint, credentials: credential, hostKey: .acceptAnything())
            #expect(await sftp.isConnected)
            await sftp.close()
        }
    }

    @Test func onlyEncryptedKeysAskForAPassphrase() async throws {
        let server = try LocalSSHServer()
        let encrypted = try server.authorizeKey("encrypted", ["-t", "ed25519", "-N", "secret"])
        let data = try Data(contentsOf: encrypted)
        await #expect(throws: SFTPFileSystem.KeyNeedsPassphrase.self) {
            _ = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(data, path: encrypted.path, passphrase: nil), hostKey: .acceptAnything())
        }
        let sftp = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(data, path: encrypted.path, passphrase: "secret"), hostKey: .acceptAnything())
        await sftp.close()
        await #expect(throws: RemoteError.unsupportedKey(encrypted.path), "a wrong passphrase") {
            _ = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(data, path: encrypted.path, passphrase: "wrong"), hostKey: .acceptAnything())
        }
        let rsa = try server.authorizeKey("encrypted-rsa", ["-t", "rsa", "-N", "secret"])
        let rsaSFTP = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(try Data(contentsOf: rsa), path: rsa.path, passphrase: "secret"), hostKey: .acceptAnything())
        await rsaSFTP.close()
        // Citadel can't decrypt PEM keys, so asking for their passphrase would only fail later.
        let pem = try server.authorizeKey("encrypted-pem", ["-t", "rsa", "-m", "PEM", "-N", "secret"])
        await #expect(throws: RemoteError.unsupportedKey(pem.path)) {
            _ = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(try Data(contentsOf: pem), path: pem.path, passphrase: nil), hostKey: .acceptAnything())
        }
    }

    @Test func rejectsUnknownKeysAndUntrustedHosts() async throws {
        let server = try LocalSSHServer()
        let wrong = try TestDirectory()
        try Data("not a key".utf8).write(to: wrong.path("key"))
        await #expect(throws: RemoteError.unsupportedKey(wrong.path("key").path)) {
            _ = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .privateKey(Data("not a key".utf8), path: wrong.path("key").path, passphrase: nil), hostKey: .acceptAnything())
        }
        await #expect(throws: RemoteError.authenticationFailed(server.endpoint.displayName)) {
            _ = try await SFTPFileSystem.connect(to: server.endpoint, credentials: .password("wrong"), hostKey: .acceptAnything())
        }
        await #expect(throws: RemoteError.hostKeyRejected(server.endpoint.displayName)) {
            _ = try await SFTPFileSystem.connect(to: server.endpoint, credentials: try server.credentials, hostKey: .trustedKeys([]))
        }
    }
}

nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var value: Int { lock.withLock { total } }
    func add(_ amount: Int) { lock.withLock { total += amount } }
}
