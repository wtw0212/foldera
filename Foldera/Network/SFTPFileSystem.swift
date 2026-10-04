import Citadel
import Crypto
import Darwin
import Foundation
import NIOCore
import NIOSSH

/// How to sign in to an SFTP server.
nonisolated enum SFTPCredentials: Sendable {
    case password(String)
    /// A private key file (see `SSHPrivateKey` for the formats) and its passphrase, if it has one.
    case privateKey(Data, path: String, passphrase: String?)
}

/// An SFTP session over one SSH connection, built on Citadel.
/// Citadel's client types aren't Sendable; they are thread-safe because every call hops to their NIO
/// event loop, and each file handle is used by one task at a time.
nonisolated final class SFTPFileSystem: RemoteFileSystem, @unchecked Sendable {
    /// Reads are requested in chunks this size; OpenSSH's sftp-server serves up to 256 KB per request.
    static let chunkSize = 64 * 1024
    /// Citadel splits writes at 32,000 bytes (swift-nio-ssh#99), so uploads send requests of that size.
    static let writeSize = 32_000
    /// Requests kept in flight, like OpenSSH's sftp: waiting for each reply limits a transfer to one chunk per round trip.
    static let pipelineDepth = 32
    /// The SSH channel window, which caps how much a download can have in flight. NIOSSH defaults to 128 KB.
    static let windowSize = 1 << 22

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
        settings.protocolOptions = [.maximumPacketSize(windowSize)]
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
                return try SSHPrivateKey.authenticationMethod(username: user, key: text, passphrase: decryption)
            } catch let error as KeyNeedsPassphrase {
                throw error
            } catch {
                // Includes a wrong passphrase, which Citadel reports as an unreadable key.
                throw RemoteError.unsupportedKey(path)
            }
        }
    }

    /// The key is encrypted and no passphrase was given.
    struct KeyNeedsPassphrase: Error {}

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
        let handle: FileHandle
        do {
            handle = try FileOperations.createFileExclusively(at: local)
        } catch {
            try? await file.close()
            throw error // An occupied destination is not ours to remove.
        }
        defer { try? handle.close() }
        do {
            let knownSize = try? await file.readAttributes().size
            var reads: [Task<ByteBuffer, Error>] = []
            var next: UInt64 = 0, offset: UInt64 = 0, atEnd = false
            while true {
                // Ask ahead up to the known size; past it, one read at a time confirms the end.
                while !atEnd, reads.count < (knownSize.map { next < $0 } ?? true ? Self.pipelineDepth : 1) {
                    let start = next
                    reads.append(Task { try await file.read(from: start, length: UInt32(Self.chunkSize)) })
                    next += UInt64(Self.chunkSize)
                }
                guard !reads.isEmpty else { break }
                let read = reads.removeFirst()
                var chunk = try await translate(path) { try await read.value }
                guard chunk.readableBytes > 0, let bytes = chunk.readBytes(length: chunk.readableBytes) else {
                    atEnd = true
                    continue
                }
                try handle.write(contentsOf: bytes)
                offset += UInt64(bytes.count)
                try written(bytes.count)
                if bytes.count < Self.chunkSize, !atEnd {
                    // A short read: drop what was asked after it and continue from here.
                    for later in reads { _ = try? await later.value }
                    reads.removeAll()
                    next = offset
                }
            }
            let attributes = try? await file.readAttributes()
            try? await file.close()
            if let modified = attributes?.accessModificationTime?.modificationTime {
                let time = timeval(tv_sec: Int(modified.timeIntervalSince1970), tv_usec: 0)
                var times = [time, time]
                _ = futimes(handle.fileDescriptor, &times)
            }
        } catch {
            try? await file.close()
            var owned = stat(), current = stat()
            if fstat(handle.fileDescriptor, &owned) == 0, lstat(local.path, &current) == 0,
               owned.st_dev == current.st_dev, owned.st_ino == current.st_ino {
                _ = unlink(local.path)
            }
            throw error
        }
    }

    func upload(_ local: URL, to path: String, written: @Sendable (Int) throws -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        nonisolated(unsafe) let file = try await translate(path) {
            try await self.sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        }
        var writes: [(size: Int, task: Task<Void, Error>)] = []
        do {
            var offset: UInt64 = 0
            var finished = false
            while !finished || !writes.isEmpty {
                while !finished, writes.count < Self.pipelineDepth {
                    guard let data = try handle.read(upToCount: Self.writeSize), !data.isEmpty else {
                        finished = true
                        break
                    }
                    let start = offset
                    writes.append((data.count, Task { try await file.write(ByteBuffer(bytes: data), at: start) }))
                    offset += UInt64(data.count)
                }
                guard !writes.isEmpty else { break }
                let write = writes.removeFirst()
                try await translate(path) { try await write.task.value }
                try written(write.size)
            }
            if let modified = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                try? await file.setAttributes(to: SFTPFileAttributes(accessModificationTime: .init(accessTime: modified, modificationTime: modified)))
            }
            try await translate(path) { try await file.close() }
        } catch {
            // Let requests already sent finish before the handle closes.
            for write in writes { _ = try? await write.task.value }
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
