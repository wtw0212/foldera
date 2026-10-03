import Foundation
import Testing
@testable import Foldera

/// Real SFTP against a local OpenSSH server.
@Suite(.serialized)
struct SFTPFileSystemTests {
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
        try await sftp.uploadAtomically(replacement, to: remoteFile) { _ in }
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
