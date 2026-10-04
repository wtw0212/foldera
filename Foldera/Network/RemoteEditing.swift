import AppKit
import Darwin
import Observation

/// Opens server files WinSCP-style: keeps a private editing copy and uploads each save.
/// Synchronized copies are removed when editing ends; unsent edits survive for explicit recovery.
@Observable
final class RemoteEditing {
    static let shared = RemoteEditing()

    struct Session: Equatable {
        let remote: URL
        let local: URL
        var uploadedVersion: Date?
        /// A save that couldn't be uploaded yet: retried after `retryAt`, and reported once.
        var failedVersion: Date?
        var retryAt: Date?
        var failures = 0
        /// Relaunch recovery waits for the user before writing an old edit back to the server.
        var isRecovered = false
        var directory: URL { local.deletingLastPathComponent().deletingLastPathComponent() }

        /// Saved but not on the server yet.
        var isPending: Bool { failedVersion != nil }
    }

    /// Relative names only: recovery records cannot point cleanup outside their directory.
    private struct Record: Codable {
        let remote: URL
        let name: String
        let uploadedVersion: Date?
        var closed = false
    }

    private(set) var sessions: [Session] = []
    private let connections: RemoteConnections
    let folder: URL
    private let openFile: (URL) -> Void
    /// First wait before retrying a failed upload; doubles up to a minute.
    private let retryDelay: TimeInterval
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?

    init(
        connections: RemoteConnections = .shared,
        folder: URL? = nil,
        openFile: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        retryDelay: TimeInterval = 5
    ) {
        self.retryDelay = retryDelay
        self.connections = connections
        self.folder = folder ?? Self.defaultFolder
        self.openFile = openFile
        if folder == nil, !Self.isTestHost {
            // Older copies have no upload records: preserve them for manual recovery.
            let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("Foldera Remote Files")
            if FileOperations.exists(legacy) {
                try? prepareFolder()
                let destination = FileOperations.uniqueURL(named: "Recovered Temporary Files", in: self.folder)
                try? FileOperations.moveItem(legacy, to: destination)
            }
        }
        restoreSessions()
    }

    private static var defaultFolder: URL {
        if isTestHost {
            return FileManager.default.temporaryDirectory.appendingPathComponent("FolderaRemoteEditingTests-\(UUID())")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foldera/Remote Files", isDirectory: true)
    }

    /// Unit and UI test hosts never recover or migrate the user's real editing copies.
    private static var isTestHost: Bool {
        Bundle.main.bundleIdentifier == "com.wtw0212.foldera.test-host"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    isolated deinit { timer?.invalidate() }

    /// Downloads `remote` and opens it. Saving the copy uploads it back.
    @discardableResult
    func open(_ remote: URL) async throws -> URL {
        guard let endpoint = remote.remoteEndpoint else { throw RemoteError.failed(L10n.text("This address is missing a user name.")) }
        let name = RemotePath.name(of: remote.remotePath)
        guard Self.validName(name) else { throw FileOperations.OperationError.invalidName(name) }
        try prepareFolder()
        let directory = folder.appendingPathComponent(UUID().uuidString)
        let files = directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let local = files.appendingPathComponent(name)
        do {
            try await connections.read(endpoint) { try await $0.download(remote.remotePath, to: local) { _ in } }
            let session = Session(remote: endpoint.url(path: remote.remotePath), local: local, uploadedVersion: Self.version(of: local))
            try persist(session)
            sessions.append(session)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        openFile(local)
        startWatching()
        return local
    }

    var hasRecoveredSessions: Bool { sessions.contains(where: \.isRecovered) }
    var isUploading: Bool { uploadTask != nil }

    func resumeRecoveredEdits() {
        for index in sessions.indices where sessions[index].isRecovered {
            sessions[index].isRecovered = false
            openFile(sessions[index].local)
        }
        startWatching()
    }

    /// An explicit end of editing. Failed saves keep their copies and continue retrying.
    func finishEditing() async {
        await uploadNow()
        do { try cleanSynchronizedSessions() } catch { BrowserTab.present(error) }
    }

    /// Called only after quitting is accepted. Unsent/recovered/in-flight edits are retained.
    func prepareToQuit() {
        stopWatching()
        if !isUploading { try? cleanSynchronizedSessions() }
    }

    /// Copies saved since their last upload (not yet on the server), for the quit warning.
    var pendingFiles: [String] {
        sessions.filter { session in
            guard let version = Self.version(of: session.local) else { return false }
            return version != session.uploadedVersion
        }.map(\.local.lastPathComponent)
    }

    /// Tries every pending upload now, ignoring backoff (before quitting).
    func uploadNow() async {
        if let uploadTask { await uploadTask.value }
        for index in sessions.indices { sessions[index].retryAt = nil }
        await uploadChanges()
    }

    /// Uploads every copy saved since its last upload. Runs every second while files are open.
    func uploadChanges() async {
        if let uploadTask { await uploadTask.value; return }
        let task = Task {
            await performUploads()
            uploadTask = nil
        }
        uploadTask = task
        await task.value
    }

    private func performUploads() async {
        let now = Date()
        for index in sessions.indices {
            let session = sessions[index]
            guard !session.isRecovered, let version = Self.version(of: session.local) else { continue }
            guard version != session.uploadedVersion, let endpoint = session.remote.remoteEndpoint else { continue }
            // A failed save is retried with backoff; a newer save is tried straight away.
            if version == session.failedVersion, let retryAt = session.retryAt, now < retryAt { continue }
            do {
                // Staged, so a dropped connection never leaves a half-written file on the server.
                try await connections.upload(session.local, replacing: session.remote.remotePath, on: endpoint) { _ in }
                sessions[index].uploadedVersion = version
                sessions[index].failedVersion = nil
                sessions[index].retryAt = nil
                sessions[index].failures = 0
                try persist(sessions[index])
            } catch {
                // The save stays pending: it's retried until it reaches the server. Each version is reported once.
                let isNewFailure = session.failedVersion != version
                sessions[index].failedVersion = version
                sessions[index].failures += 1
                sessions[index].retryAt = now.addingTimeInterval(min(60, retryDelay * pow(2, Double(sessions[index].failures - 1))))
                if isNewFailure {
                    BrowserTab.present(RemoteError.failed(L10n.format("“%@” couldn’t be uploaded to the server yet: %@ Foldera keeps trying while it’s open.", session.local.lastPathComponent, error.localizedDescription)))
                }
            }
        }
        for session in sessions where !FileOperations.exists(session.local) {
            try? FileManager.default.removeItem(at: session.directory)
        }
        sessions.removeAll { !FileOperations.exists($0.local) }
        if sessions.allSatisfy(\.isRecovered) { stopWatching() }
    }

    private func cleanSynchronizedSessions() throws {
        guard !isUploading else { return }
        for index in sessions.indices.reversed() {
            let session = sessions[index]
            guard !session.isRecovered, let version = Self.version(of: session.local), version == session.uploadedVersion else { continue }
            // A closed record allows the next launch to finish an interrupted cleanup.
            try persist(session, closed: true)
            try FileManager.default.removeItem(at: session.directory)
            sessions.remove(at: index)
        }
        if sessions.allSatisfy(\.isRecovered) { stopWatching() }
    }

    private func persist(_ session: Session, closed: Bool = false) throws {
        let record = Record(remote: session.remote, name: session.local.lastPathComponent, uploadedVersion: session.uploadedVersion, closed: closed)
        let url = session.directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func prepareFolder() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        var cache = folder, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try cache.setResourceValues(values)
    }

    private func restoreSessions() {
        let fm = FileManager.default
        for directory in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard UUID(uuidString: directory.lastPathComponent) != nil, Self.isDirectory(directory) else { continue }
            let metadata = directory.appendingPathComponent("session.json")
            let files = directory.appendingPathComponent("files", isDirectory: true)
            guard Self.version(of: metadata) != nil, Self.isDirectory(files),
                  let data = try? Data(contentsOf: metadata), let record = try? JSONDecoder().decode(Record.self, from: data),
                  Self.validName(record.name), let endpoint = record.remote.remoteEndpoint else { continue }
            let local = files.appendingPathComponent(record.name)
            if record.closed, let version = Self.version(of: local), version == record.uploadedVersion {
                try? fm.removeItem(at: directory)
            } else if Self.version(of: local) != nil {
                sessions.append(Session(remote: endpoint.url(path: record.remote.remotePath), local: local, uploadedVersion: record.uploadedVersion, isRecovered: true))
            }
        }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private func startWatching() {
        guard timer == nil, sessions.contains(where: { !$0.isRecovered }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.uploadChanges() }
            }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    /// Read fresh each time; URL resource values can be cached.
    private static func version(of url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
