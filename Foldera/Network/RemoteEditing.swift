import AppKit

/// Opens server files WinSCP-style: downloads a temporary copy, opens it in its app, and uploads it
/// again each time it's saved.
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

        /// Saved but not on the server yet.
        var isPending: Bool { failedVersion != nil }
    }

    private(set) var sessions: [Session] = []
    private let connections: RemoteConnections
    private let folder: URL
    private let openFile: (URL) -> Void
    /// First wait before retrying a failed upload; doubles up to a minute.
    private let retryDelay: TimeInterval
    private var timer: Timer?
    private var isChecking = false

    init(
        connections: RemoteConnections = .shared,
        folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Foldera Remote Files"),
        openFile: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        retryDelay: TimeInterval = 5
    ) {
        self.retryDelay = retryDelay
        self.connections = connections
        self.folder = folder
        self.openFile = openFile
    }

    /// Downloads `remote` and opens it. Saving the copy uploads it back.
    @discardableResult
    func open(_ remote: URL) async throws -> URL {
        guard let endpoint = remote.remoteEndpoint else { throw RemoteError.failed(L10n.text("This address is missing a user name.")) }
        let directory = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent(RemotePath.name(of: remote.remotePath))
        do {
            try await connections.read(endpoint) { try await $0.download(remote.remotePath, to: local) { _ in } }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        sessions.append(Session(remote: remote, local: local, uploadedVersion: Self.version(of: local)))
        openFile(local)
        startWatching()
        return local
    }

    /// Uploads every copy saved since its last upload. Runs every second while files are open.
    func uploadChanges() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let now = Date()
        for index in sessions.indices {
            let session = sessions[index]
            guard let version = Self.version(of: session.local) else { continue }
            guard version != session.uploadedVersion, let endpoint = session.remote.remoteEndpoint else { continue }
            // A failed save is retried with backoff; a newer save is tried straight away.
            if version == session.failedVersion, let retryAt = session.retryAt, now < retryAt { continue }
            do {
                // Staged, so a dropped connection never leaves a half-written file on the server.
                try await connections.perform(endpoint) { try await $0.uploadAtomically(session.local, to: session.remote.remotePath) { _ in } }
                sessions[index].uploadedVersion = version
                sessions[index].failedVersion = nil
                sessions[index].retryAt = nil
                sessions[index].failures = 0
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
        // A deleted copy has nothing left to upload.
        sessions.removeAll { !FileManager.default.fileExists(atPath: $0.local.path) }
        if sessions.isEmpty { stopWatching() }
    }

    private func startWatching() {
        guard timer == nil else { return }
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
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
