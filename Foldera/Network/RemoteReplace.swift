import Foundation

/// A replacement on a server that moved the old item aside under a hidden backup name. It is recorded until
/// it's settled, so a dropped connection or a quit never strands the old item there.
nonisolated struct PendingSwap: Codable, Hashable, Sendable {
    let endpoint: RemoteEndpoint
    let path: String
    let backup: String
    /// Foldera's own staging copy, deleted once settled. Nil when the new item is the user's (a move).
    var staging: String?
    /// Private directories acquired by successful, exclusive mkdir. Nil for records from older versions.
    var backupDirectory: String? = nil
    var stagingDirectory: String? = nil
}

/// Replacements not yet settled, kept in the user defaults so they're finished after a relaunch too.
final class SwapJournal {
    private let defaults: UserDefaults?
    private static let key = "pendingRemoteSwaps"
    private(set) var swaps: [PendingSwap]

    /// With no defaults the journal lasts only as long as the app (unit tests).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        swaps = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([PendingSwap].self, from: $0) } ?? []
    }

    func add(_ swap: PendingSwap) {
        swaps.append(swap)
        persist()
    }

    func remove(_ swap: PendingSwap) {
        swaps.removeAll { $0 == swap }
        persist()
    }

    private func persist() {
        defaults?.set(try? JSONEncoder().encode(swaps), forKey: Self.key)
    }
}

extension RemoteConnections {
    /// Uploads `local` under a hidden staging name, then commits it over `path`, so a failed upload leaves
    /// the server's copy as it was.
    func upload(_ local: URL, replacing path: String, on endpoint: RemoteEndpoint, written: @Sendable (Int) throws -> Void) async throws {
        let directory = try await reserveTemporaryDirectory(beside: path, suffix: "part", on: endpoint)
        let staging = RemotePath.join(directory, "payload")
        do {
            try await perform(endpoint) { try await $0.upload(local, to: staging, written: written) }
            try await commit(staging, to: path, on: endpoint, replacing: true, isStaging: true, stagingDirectory: directory)
        } catch {
            try? await discardTemporaryDirectory(directory, on: endpoint)
            throw error
        }
    }

    /// Renames `item` to `path`. SFTP renames can't overwrite, so when `replacing`, an existing item is first
    /// renamed to a hidden backup, which is deleted only once the new item is in place.
    ///
    /// A rename whose reply was lost (a dropped connection) may still have happened, so after any failure
    /// the server is looked at again over a fresh connection: if `item` reached `path` the commit counts as
    /// done; otherwise the old item is renamed back. What can't be settled now stays in the journal and is
    /// settled when the server is next connected.
    func commit(_ item: String, to path: String, on endpoint: RemoteEndpoint, replacing: Bool, isStaging: Bool, stagingDirectory: String? = nil) async throws {
        var swap: PendingSwap?
        if replacing, try await read(endpoint, { try await $0.unfollowedEntry(at: path) }) != nil {
            let directory = try await reserveTemporaryDirectory(beside: path, suffix: "old", on: endpoint)
            swap = PendingSwap(endpoint: endpoint, path: path, backup: RemotePath.join(directory, "payload"),
                               staging: isStaging ? item : nil, backupDirectory: directory, stagingDirectory: stagingDirectory)
        }
        if let swap {
            journal.add(swap)
            swapsInFlight.insert(swap)
        }
        defer { if let swap { swapsInFlight.remove(swap) } }
        do {
            if let swap { try await perform(endpoint) { try await $0.rename(path, to: swap.backup) } }
            try await perform(endpoint) { try await $0.rename(item, to: path) }
        } catch {
            let committed = (try? await read(endpoint) { system in
                guard try await system.unfollowedEntry(at: item) == nil else { return false }
                return try await system.unfollowedEntry(at: path) != nil
            }) ?? false
            if let swap { try? await settle(swap) }
            if !committed { throw error }
        }
        if let swap { try? await settle(swap) }
        else if let stagingDirectory { try? await discardTemporaryDirectory(stagingDirectory, on: endpoint) }
    }

    /// Finishes a swap: restores the old item if the new one never arrived, otherwise deletes the backup;
    /// then deletes a leftover staging copy and forgets the swap. New swaps keep their payloads inside
    /// private directories acquired by exclusive mkdir, rather than assuming an absent name is reserved.
    func settle(_ swap: PendingSwap) async throws {
        try await perform(swap.endpoint) { system in
            try await settle(swap, using: system)
        }
    }

    func settle(_ swap: PendingSwap, using system: any RemoteFileSystem) async throws {
        let backupDirectoryExists = if let directory = swap.backupDirectory {
            try await system.unfollowedEntry(at: directory) != nil
        } else { true }
        if backupDirectoryExists, let backup = try await system.unfollowedEntry(at: swap.backup) {
            if try await system.unfollowedEntry(at: swap.path) == nil {
                try await system.rename(swap.backup, to: swap.path)
            } else {
                try await system.removeRecursively(backup)
            }
        }
        if let directory = swap.stagingDirectory {
            try await discardTemporaryDirectory(directory, using: system)
        } else if let staging = swap.staging, let entry = try await system.unfollowedEntry(at: staging) {
            try await system.removeRecursively(entry) // legacy staging lives directly beside the destination
        }
        if let directory = swap.backupDirectory, backupDirectoryExists { try await system.removeDirectory(directory) }
        journal.remove(swap)
    }

    /// Settles abandoned swaps before a connection becomes usable; active commits recover their own swaps.
    func settleLeftoverSwaps(on endpoint: RemoteEndpoint, using system: any RemoteFileSystem) async throws {
        while let swap = journal.swaps.first(where: { $0.endpoint == endpoint && !swapsInFlight.contains($0) }) {
            try await settle(swap, using: system)
        }
    }

    /// Acquires a private sibling directory atomically. Its name is independent of the destination's length.
    /// A failed mkdir never authorizes cleanup, even if its reply was lost after the server created it.
    func reserveTemporaryDirectory(beside path: String, suffix: String, on endpoint: RemoteEndpoint) async throws -> String {
        let parent = RemotePath.parent(of: path)
        for _ in 0..<3 {
            let candidate = RemotePath.join(parent, ".foldera-\(uniqueToken()).\(suffix)")
            do {
                try await perform(endpoint) { try await $0.makeDirectory(candidate, permissions: 0o700) }
                return candidate
            } catch {
                // An occupied name is someone else's; retry under a fresh one without touching it.
                guard try await read(endpoint, { try await $0.unfollowedEntry(at: candidate) }) != nil else { throw error }
            }
        }
        throw RemoteError.alreadyExists(RemotePath.name(of: path))
    }

    func discardTemporaryDirectory(_ directory: String, on endpoint: RemoteEndpoint) async throws {
        try await perform(endpoint) { try await discardTemporaryDirectory(directory, using: $0) }
    }

    private func discardTemporaryDirectory(_ directory: String, using system: any RemoteFileSystem) async throws {
        guard try await system.unfollowedEntry(at: directory) != nil else { return }
        if let payload = try await system.unfollowedEntry(at: RemotePath.join(directory, "payload")) {
            try await system.removeRecursively(payload)
        }
        // Only remove an empty container; unexpected additional items are retained.
        try await system.removeDirectory(directory)
    }
}
