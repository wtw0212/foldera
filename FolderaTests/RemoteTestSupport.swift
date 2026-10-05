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
    private var drops: [String: (skip: Int, applied: Bool)] = [:]
    private let beforeList: (@Sendable () async -> Void)?
    private let beforeUpload: (@Sendable () async -> Void)?
    private let beforeMakeDirectory: (@Sendable (String) async throws -> Void)?
    private let beforeRename: (@Sendable (String, String) async throws -> Void)?
    let homePath: String

    init(home: String = NSHomeDirectory(), beforeList: (@Sendable () async -> Void)? = nil, beforeUpload: (@Sendable () async -> Void)? = nil,
         beforeMakeDirectory: (@Sendable (String) async throws -> Void)? = nil,
         beforeRename: (@Sendable (String, String) async throws -> Void)? = nil) {
        homePath = home
        self.beforeList = beforeList
        self.beforeUpload = beforeUpload
        self.beforeMakeDirectory = beforeMakeDirectory
        self.beforeRename = beforeRename
    }

    var operations: [String] { lock.withLock { calls } }
    var isConnected: Bool { lock.withLock { connected } }

    func disconnect() { lock.withLock { connected = false } }
    /// Brings a dropped connection back, as signing in again would. For connectors in tests.
    func reconnect() -> FakeRemoteFileSystem {
        lock.withLock { connected = true }
        return self
    }
    /// Lets `skip` calls to `operation` succeed, then drops the connection during the next one. With
    /// `applied`, the server carries it out but the reply is lost. Every later call fails until `reconnect()`.
    func simulateConnectionDrop(_ operation: String, afterCalls skip: Int = 0, applied: Bool) { lock.withLock { drops[operation] = (skip, applied) } }
    /// The next call to `operation` throws `error`.
    func fail(_ operation: String, with error: Error) { lock.withLock { failures[operation] = error } }
    /// Lets `skip` calls to `operation` succeed, then fails the next one (e.g. the second rename of a swap).
    func fail(_ operation: String, with error: Error, afterCalls skip: Int) { lock.withLock { delayed[operation] = (skip, error) } }
    /// The next upload or download writes half the file, then throws (a dropped connection).
    func failPartway(_ operation: String, with error: Error) { lock.withLock { partway[operation] = error } }
    private func partwayFailure(_ operation: String) -> Error? { lock.withLock { partway.removeValue(forKey: operation) } }

    private static let lost = RemoteError.failed("connection lost")

    /// Records a call and throws any failure set up for it. Returns whether the connection drops once the
    /// call is carried out (`finish` throws then).
    @discardableResult
    private func record(_ operation: String) throws -> Bool {
        let failure: Error? = lock.withLock {
            guard connected else { return Self.lost }
            calls.append(operation)
            if let drop = drops[operation] {
                if drop.skip == 0 {
                    drops[operation] = nil
                    connected = false
                    return drop.applied ? nil : Self.lost
                }
                drops[operation] = (drop.skip - 1, drop.applied)
            }
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
        return lock.withLock { !connected }
    }

    /// Throws for a call whose reply was lost.
    private func finish(_ dropped: Bool) throws {
        if dropped { throw Self.lost }
    }

    private let fileManager = FileManager.default

    func home() async throws -> String {
        try record("home")
        return homePath
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        try record("list")
        await beforeList?()
        guard fileManager.fileExists(atPath: path) else { throw RemoteError.notFound(RemotePath.name(of: path)) }
        return try fileManager.contentsOfDirectory(atPath: path).map { try Self.entry(RemotePath.join(path, $0), followLinks: false) }
    }

    func entry(at path: String) async throws -> RemoteEntry? {
        try record("entry")
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try Self.entry(path, followLinks: true)
    }

    func makeDirectory(_ path: String, permissions: UInt32?) async throws {
        let dropped = try record("makeDirectory")
        try await beforeMakeDirectory?(path)
        guard mkdir(path, mode_t(permissions ?? 0o777)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try finish(dropped)
    }

    func createFile(_ path: String) async throws {
        try record("createFile")
        guard fileManager.createFile(atPath: path, contents: Data()) else { throw RemoteError.failed("create") }
    }

    func rename(_ path: String, to newPath: String) async throws {
        let dropped = try record("rename")
        try await beforeRename?(path, newPath)
        try fileManager.moveItem(atPath: path, toPath: newPath)
        try finish(dropped)
    }

    func removeFile(_ path: String) async throws {
        let dropped = try record("removeFile")
        try fileManager.removeItem(atPath: path)
        try finish(dropped)
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
        await beforeUpload?()
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
