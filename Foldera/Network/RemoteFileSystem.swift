import Foundation

/// One item on a remote server.
nonisolated struct RemoteEntry: Hashable, Sendable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?
    let permissions: UInt32?

    var name: String { RemotePath.name(of: path) }
}

/// A connected remote file system. `SFTPFileSystem` talks to real servers; tests use a local stand-in.
/// Paths are absolute POSIX paths on the server.
nonisolated protocol RemoteFileSystem: AnyObject, Sendable {
    /// False once the connection has dropped; the next operation reconnects.
    var isConnected: Bool { get async }
    /// The login folder, where a site opens when it has no start folder.
    func home() async throws -> String
    func list(_ path: String) async throws -> [RemoteEntry]
    /// Nil when nothing exists at `path`.
    func entry(at path: String) async throws -> RemoteEntry?
    /// Creates a directory exclusively: an existing file, directory or link must cause an error.
    func makeDirectory(_ path: String, permissions: UInt32?) async throws
    func createFile(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    /// Streams a file to `local`, calling `written` with each chunk's size; `written` throws to cancel.
    func download(_ path: String, to local: URL, written: @Sendable (Int) throws -> Void) async throws
    /// Streams `local` to a new or truncated file at `path`.
    func upload(_ local: URL, to path: String, written: @Sendable (Int) throws -> Void) async throws
    func close() async
}

nonisolated extension RemoteFileSystem {
    func makeDirectory(_ path: String) async throws {
        try await makeDirectory(path, permissions: nil)
    }

    /// The item at `path` as its folder lists it, so a symbolic link is reported as a link
    /// (`entry(at:)` follows links). Nil when it doesn't exist.
    func unfollowedEntry(at path: String) async throws -> RemoteEntry? {
        let path = RemotePath.normalize(path)
        guard path != "/" else { return try await entry(at: path) }
        return try await list(RemotePath.parent(of: path)).first { $0.path == path }
    }

    /// Deletes a file, or a folder and everything in it. Symbolic links are removed, never followed.
    func removeRecursively(_ entry: RemoteEntry) async throws {
        if entry.isDirectory && !entry.isSymlink {
            for child in try await list(entry.path) {
                try await removeRecursively(child)
            }
            try await removeDirectory(entry.path)
        } else {
            try await removeFile(entry.path)
        }
    }

    /// Bytes in a file or folder tree.
    func totalSize(_ entry: RemoteEntry) async throws -> Int64 {
        guard entry.isDirectory, !entry.isSymlink else { return entry.size ?? 0 }
        var total: Int64 = 0
        for child in try await list(entry.path) {
            total += try await totalSize(child)
        }
        return total
    }

    /// "name", "name (2)", … like `FileOperations.uniqueURL`, but on the server.
    func uniquePath(named name: String, in directory: String, copySuffix: Bool = false) async throws -> String {
        let candidate = RemotePath.join(directory, name)
        if try await entry(at: candidate) == nil { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func make(_ base: String) -> String {
            RemotePath.join(directory, ext.isEmpty ? base : "\(base).\(ext)")
        }
        let base = copySuffix ? "\(stem) - Copy" : stem
        if copySuffix, try await entry(at: make(base)) == nil { return make(base) }
        var index = 2
        while try await entry(at: make("\(base) (\(index))")) != nil { index += 1 }
        return make("\(base) (\(index))")
    }
}

nonisolated enum RemoteError: LocalizedError, Equatable {
    case notConnected(String)
    case authenticationFailed(String)
    case hostKeyRejected(String)
    case unsupportedKey(String)
    case notFound(String)
    case alreadyExists(String)
    case failed(String)

    var errorDescription: String? {
        let language = AppLanguage.saved
        return switch self {
        case .notConnected(let server):
            L10n.format("Foldera couldn’t connect to %@.", language: language, arguments: [server])
        case .authenticationFailed(let server):
            L10n.format("The user name, password or key was not accepted by %@.", language: language, arguments: [server])
        case .hostKeyRejected(let server):
            L10n.format("The connection to %@ was cancelled because its identity wasn’t trusted.", language: language, arguments: [server])
        case .unsupportedKey(let path):
            L10n.format("“%@” isn’t a supported private key. Use an Ed25519, ECDSA or RSA key in OpenSSH or PEM format. PEM keys can’t have a passphrase.", language: language, arguments: [path])
        case .notFound(let name):
            L10n.format("“%@” no longer exists on the server.", language: language, arguments: [name])
        case .alreadyExists(let name):
            L10n.format("An item named “%@” already exists in this location.", language: language, arguments: [name])
        case .failed(let message):
            message
        }
    }
}
