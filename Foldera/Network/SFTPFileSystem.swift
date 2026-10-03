import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// How to sign in to an SFTP server.
nonisolated enum SFTPCredentials: Sendable {
    case password(String)
    /// An OpenSSH private key file (Ed25519 or RSA) and its passphrase, if it has one.
    case privateKey(Data, path: String, passphrase: String?)
}

/// An SFTP session over one SSH connection, built on Citadel.
/// Citadel's client types aren't Sendable; they are thread-safe because every call hops to their NIO
/// event loop, and each file handle is used by one task at a time.
nonisolated final class SFTPFileSystem: RemoteFileSystem, @unchecked Sendable {
    /// Reads are requested in chunks this size; OpenSSH's sftp-server serves up to 256 KB per request.
    static let chunkSize = 64 * 1024

    nonisolated(unsafe) private let client: SSHClient
    private let sftp: SFTPClient

    private init(client: SSHClient, sftp: SFTPClient) {
        self.client = client
        self.sftp = sftp
    }

    /// Connects and starts the SFTP subsystem. `hostKey` decides whether to trust the server's key.
    static func connect(
        to endpoint: RemoteEndpoint,
        credentials: SFTPCredentials,
        hostKey: SSHHostKeyValidator,
        timeout: Duration = .seconds(15)
    ) async throws -> SFTPFileSystem {
        // Parse the key up front so a bad key or missing passphrase is reported before connecting.
        _ = try authenticationMethod(for: endpoint.username, credentials)
        let user = endpoint.username
        var settings = SSHClientSettings(
            host: endpoint.host,
            port: endpoint.port,
            // Citadel asks for a fresh method per attempt; parsing succeeded above, so this can't throw.
            authenticationMethod: { try! authenticationMethod(for: user, credentials) },
            hostKeyValidator: hostKey
        )
        settings.connectTimeout = .milliseconds(Int64(timeout.components.seconds * 1000))
        let client: SSHClient
        do {
            client = try await SSHClient.connect(to: settings)
        } catch is InvalidHostKey {
            throw RemoteError.hostKeyRejected(endpoint.displayName)
        } catch let error as SSHClientError {
            if case .allAuthenticationOptionsFailed = error { throw RemoteError.authenticationFailed(endpoint.displayName) }
            throw RemoteError.notConnected(endpoint.displayName)
        } catch is HostKeyRejected {
            throw RemoteError.hostKeyRejected(endpoint.displayName)
        } catch {
            if Self.isAuthenticationFailure(error) { throw RemoteError.authenticationFailed(endpoint.displayName) }
            // Refused, unreachable or timed out: NIO's own descriptions aren't meant for people.
            throw RemoteError.notConnected(endpoint.displayName)
        }
        do {
            return SFTPFileSystem(client: client, sftp: try await client.openSFTP())
        } catch {
            try? await client.close()
            throw RemoteError.failed(L10n.format("%@ doesn’t offer SFTP.", language: .saved, arguments: [endpoint.displayName]))
        }
    }

    /// Thrown by Foldera's host key prompt when the user declines the server.
    struct HostKeyRejected: Error {}

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        String(describing: error).localizedCaseInsensitiveContains("authentication")
    }

    private static func authenticationMethod(for user: String, _ credentials: SFTPCredentials) throws -> SSHAuthenticationMethod {
        switch credentials {
        case .password(let password):
            return .passwordBased(username: user, password: password)
        case .privateKey(let data, let path, let passphrase):
            guard let text = String(data: data, encoding: .utf8) else { throw RemoteError.unsupportedKey(path) }
            let decryption = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            do {
                switch try SSHKeyDetection.detectPrivateKeyType(from: text) {
                case .ed25519:
                    return .ed25519(username: user, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryption))
                case .rsa:
                    return .rsa(username: user, privateKey: try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryption))
                default:
                    throw RemoteError.unsupportedKey(path)
                }
            } catch let error as RemoteError {
                throw error
            } catch {
                throw passphrase == nil && Self.looksEncrypted(text) ? KeyNeedsPassphrase() : RemoteError.unsupportedKey(path)
            }
        }
    }

    /// The key is encrypted and no passphrase was given.
    struct KeyNeedsPassphrase: Error {}

    private static func looksEncrypted(_ key: String) -> Bool {
        // OpenSSH keys name their cipher in the base64 body; "none" means unencrypted.
        let body = key.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else { return false }
        return data.prefix(64).range(of: Data("none".utf8)) == nil
    }

    // MARK: RemoteFileSystem

    var isConnected: Bool { client.isConnected && sftp.isActive }

    func home() async throws -> String {
        try await translate { try await self.sftp.getRealPath(atPath: ".") }
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        let names = try await translate(path) { try await self.sftp.listDirectory(atPath: path) }
        var entries: [RemoteEntry] = []
        for component in names.flatMap(\.components) where component.filename != "." && component.filename != ".." {
            let childPath = RemotePath.join(path, component.filename)
            var entry = Self.entry(childPath, component.attributes, longname: component.longname)
            if entry.isSymlink, let target = try? await sftp.getAttributes(at: childPath) {
                // Links show what they point to, like Finder; deleting still removes only the link.
                let resolved = Self.entry(childPath, target, longname: "")
                entry = RemoteEntry(path: childPath, isDirectory: resolved.isDirectory, isSymlink: true,
                                    size: resolved.size, modified: resolved.modified, permissions: resolved.permissions)
            }
            entries.append(entry)
        }
        return entries
    }

    func entry(at path: String) async throws -> RemoteEntry? {
        do {
            return Self.entry(path, try await sftp.getAttributes(at: path), longname: "")
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            return nil
        } catch {
            throw Self.translated(error, path: path)
        }
    }

    func makeDirectory(_ path: String) async throws {
        try await translate(path) { try await self.sftp.createDirectory(atPath: path) }
    }

    func createFile(_ path: String) async throws {
        try await translate(path) {
            nonisolated(unsafe) let file = try await self.sftp.openFile(filePath: path, flags: [.write, .create, .forceCreate])
            try await file.close()
        }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await translate(path) { try await self.sftp.rename(at: path, to: newPath) }
    }

    func removeFile(_ path: String) async throws {
        try await translate(path) { try await self.sftp.remove(at: path) }
    }

    func removeDirectory(_ path: String) async throws {
        try await translate(path) { try await self.sftp.rmdir(at: path) }
    }

    func download(_ path: String, to local: URL, written: @Sendable (Int) throws -> Void) async throws {
        nonisolated(unsafe) let file = try await translate(path) { try await self.sftp.openFile(filePath: path, flags: .read) }
        do {
            guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: local.path])
            }
            let handle = try FileHandle(forWritingTo: local)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            while true {
                var chunk = try await translate(path) { try await file.read(from: offset, length: UInt32(Self.chunkSize)) }
                guard chunk.readableBytes > 0, let bytes = chunk.readBytes(length: chunk.readableBytes) else { break }
                try handle.write(contentsOf: bytes)
                offset += UInt64(bytes.count)
                try written(bytes.count)
            }
            let attributes = try? await file.readAttributes()
            try? await file.close()
            if let modified = attributes?.accessModificationTime?.modificationTime {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: local.path)
            }
        } catch {
            try? await file.close()
            throw error
        }
    }

    func upload(_ local: URL, to path: String, written: @Sendable (Int) throws -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        nonisolated(unsafe) let file = try await translate(path) {
            try await self.sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        }
        do {
            var offset: UInt64 = 0
            while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
                try await translate(path) { try await file.write(ByteBuffer(bytes: data), at: offset) }
                offset += UInt64(data.count)
                try written(data.count)
            }
            if let modified = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                try? await file.setAttributes(to: SFTPFileAttributes(accessModificationTime: .init(accessTime: modified, modificationTime: modified)))
            }
            try await translate(path) { try await file.close() }
        } catch {
            try? await file.close()
            throw error
        }
    }

    func close() async {
        try? await sftp.close()
        try? await client.close()
    }

    // MARK: Helpers

    private static func entry(_ path: String, _ attributes: SFTPFileAttributes, longname: String) -> RemoteEntry {
        let type = attributes.permissions.map { $0 & 0o170000 }
        let isDirectory = type.map { $0 == 0o040000 } ?? longname.hasPrefix("d")
        let isSymlink = type.map { $0 == 0o120000 } ?? longname.hasPrefix("l")
        return RemoteEntry(
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: attributes.size.map { Int64(clamping: $0) },
            modified: attributes.accessModificationTime?.modificationTime,
            permissions: attributes.permissions
        )
    }

    private func translate<T>(_ path: String = "", _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.translated(error, path: path)
        }
    }

    /// SFTP status codes become readable errors; everything else keeps its own description.
    private static func translated(_ error: Error, path: String) -> Error {
        if error is CopyEngine.Cancelled || error is RemoteError || error is CocoaError { return error }
        let name = RemotePath.name(of: path)
        if let status = error as? SFTPMessage.Status {
            switch status.errorCode {
            case .noSuchFile: return RemoteError.notFound(name)
            case .permissionDenied:
                return RemoteError.failed(L10n.format("You don’t have permission to access “%@” on the server.", language: .saved, arguments: [name]))
            default:
                return RemoteError.failed(status.message.isEmpty ? String(describing: status.errorCode) : status.message)
            }
        }
        if let error = error as? SFTPError, case .errorStatus(let status) = error {
            return translated(status, path: path)
        }
        return RemoteError.failed(L10n.text("The connection to the server was lost.", language: .saved))
    }
}
