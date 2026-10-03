import AppKit

/// Opens server files WinSCP-style: downloads a temporary copy, opens it in its app, and uploads it
/// again each time it's saved.
final class RemoteEditing {
    static let shared = RemoteEditing()

    struct Session: Equatable {
        let remote: URL
        let local: URL
        var uploadedVersion: Date?
    }

    private(set) var sessions: [Session] = []
    private let connections: RemoteConnections
    private let folder: URL
    private let openFile: (URL) -> Void
    private var timer: Timer?
    private var isChecking = false

    init(
        connections: RemoteConnections = .shared,
        folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Foldera Remote Files"),
        openFile: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
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
        try await connections.perform(endpoint) { try await $0.download(remote.remotePath, to: local) { _ in } }
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
        for index in sessions.indices {
            let session = sessions[index]
            guard let version = Self.version(of: session.local) else { continue }
            guard version != session.uploadedVersion, let endpoint = session.remote.remoteEndpoint else { continue }
            do {
                try await connections.perform(endpoint) { try await $0.upload(session.local, to: session.remote.remotePath) { _ in } }
                sessions[index].uploadedVersion = version
            } catch {
                // Don't retry the same save over and over; the next save tries again.
                sessions[index].uploadedVersion = version
                BrowserTab.present(RemoteError.failed(L10n.format("“%@” couldn’t be uploaded to the server: %@", session.local.lastPathComponent, error.localizedDescription)))
            }
        }
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
