import Foundation
@testable import Foldera

/// A stand-in server: remote paths are local paths, so tests can set up and check files directly.
nonisolated final class FakeRemoteFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = true
    private var calls: [String] = []
    private var failures: [String: Error] = [:]
    private var partway: [String: Error] = [:]
    private var delayed: [String: (skip: Int, error: Error)] = [:]
    let homePath: String

    init(home: String = NSHomeDirectory()) { homePath = home }

    var operations: [String] { lock.withLock { calls } }
    var isConnected: Bool { lock.withLock { connected } }

    func disconnect() { lock.withLock { connected = false } }
    /// The next call to `operation` throws `error`.
    func fail(_ operation: String, with error: Error) { lock.withLock { failures[operation] = error } }
    /// Lets `skip` calls to `operation` succeed, then fails the next one (e.g. the second rename of a swap).
    func fail(_ operation: String, with error: Error, afterCalls skip: Int) { lock.withLock { delayed[operation] = (skip, error) } }
    /// The next upload or download writes half the file, then throws (a dropped connection).
    func failPartway(_ operation: String, with error: Error) { lock.withLock { partway[operation] = error } }
    private func partwayFailure(_ operation: String) -> Error? { lock.withLock { partway.removeValue(forKey: operation) } }

    private func record(_ operation: String) throws {
        let failure: Error? = lock.withLock {
            calls.append(operation)
            if let pending = delayed[operation] {
                if pending.skip == 0 {
                    delayed[operation] = nil
                    return pending.error
                }
                delayed[operation] = (pending.skip - 1, pending.error)
            }
            return failures.removeValue(forKey: operation)
        }
        if let failure { throw failure }
    }

    private let fileManager = FileManager.default

    func home() async throws -> String {
        try record("home")
        return homePath
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        try record("list")
        guard fileManager.fileExists(atPath: path) else { throw RemoteError.notFound(RemotePath.name(of: path)) }
        return try fileManager.contentsOfDirectory(atPath: path).map { try Self.entry(RemotePath.join(path, $0), followLinks: false) }
    }

    func entry(at path: String) async throws -> RemoteEntry? {
        try record("entry")
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try Self.entry(path, followLinks: true)
    }

    func makeDirectory(_ path: String) async throws {
        try record("makeDirectory")
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func createFile(_ path: String) async throws {
        try record("createFile")
        guard fileManager.createFile(atPath: path, contents: Data()) else { throw RemoteError.failed("create") }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try record("rename")
        try fileManager.moveItem(atPath: path, toPath: newPath)
    }

    func removeFile(_ path: String) async throws {
        try record("removeFile")
        try fileManager.removeItem(atPath: path)
    }

    func removeDirectory(_ path: String) async throws {
        try record("removeDirectory")
        guard try fileManager.contentsOfDirectory(atPath: path).isEmpty else { throw RemoteError.failed("not empty") }
        try fileManager.removeItem(atPath: path)
    }

    func download(_ path: String, to local: URL, written: @Sendable (Int) throws -> Void) async throws {
        try record("download")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let failure = partwayFailure("download") {
            try data.prefix(data.count / 2).write(to: local)
            throw failure
        }
        try data.write(to: local)
        try written(data.count)
    }

    func upload(_ local: URL, to path: String, written: @Sendable (Int) throws -> Void) async throws {
        try record("upload")
        let data = try Data(contentsOf: local)
        if let failure = partwayFailure("upload") {
            try data.prefix(data.count / 2).write(to: URL(fileURLWithPath: path))
            throw failure
        }
        try data.write(to: URL(fileURLWithPath: path))
        try written(data.count)
    }

    func close() async {
        lock.withLock { calls.append("close"); connected = false }
    }

    private static func entry(_ path: String, followLinks: Bool) throws -> RemoteEntry {
        let manager = FileManager.default
        let own = try manager.attributesOfItem(atPath: path)
        let isLink = own[.type] as? FileAttributeType == .typeSymbolicLink
        let target = isLink ? (try? manager.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath)) ?? own : own
        let isDirectory = target[.type] as? FileAttributeType == .typeDirectory
        return RemoteEntry(
            path: path,
            isDirectory: isDirectory,
            isSymlink: isLink && !followLinks,
            size: (target[.size] as? NSNumber)?.int64Value,
            modified: target[.modificationDate] as? Date,
            permissions: (target[.posixPermissions] as? NSNumber)?.uint32Value
        )
    }
}

final class MemorySecrets: SecretStore {
    private(set) var values: [String: String] = [:]
    func secret(for account: String) -> String? { values[account] }
    func setSecret(_ value: String?, for account: String) { values[account] = value?.isEmpty == false ? value : nil }
}

/// A unique server per test, so tests sharing `RemoteConnections.shared` never see each other's connections.
@MainActor
func uniqueEndpoint(user: String = NSUserName()) -> RemoteEndpoint {
    RemoteEndpoint(host: "test-\(UUID().uuidString.prefix(8).lowercased()).invalid", port: 2200, username: user)
}

/// Installs a stand-in server for `endpoint` on the shared connections and returns it.
@MainActor
@discardableResult
func installFakeServer(_ endpoint: RemoteEndpoint, home: String = NSHomeDirectory()) -> FakeRemoteFileSystem {
    let server = FakeRemoteFileSystem(home: home)
    RemoteConnections.shared.install(server, for: endpoint)
    return server
}

/// Collects errors instead of showing alerts.
@MainActor
final class ErrorCollector {
    private(set) var errors: [Error] = []

    init() { BrowserTab.errorPresenter = { [weak self] in self?.errors.append($0) } }

    isolated deinit { BrowserTab.errorPresenter = nil }

    var messages: [String] { errors.map(\.localizedDescription) }
}
