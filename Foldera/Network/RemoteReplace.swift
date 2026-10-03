import Foundation

/// A replacement on a server that moved the old item aside under a hidden backup name. It is recorded until
/// it's settled, so a dropped connection or a quit never strands the old item there.
nonisolated struct PendingSwap: Codable, Hashable, Sendable {
    let endpoint: RemoteEndpoint
    let path: String
    let backup: String
    /// Foldera's own staging copy, deleted once settled. Nil when the new item is the user's (a move).
    var staging: String?
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
        let staging = Self.sibling(of: path, suffix: "part")
        do {
            try await perform(endpoint) { try await $0.upload(local, to: staging, written: written) }
            try await commit(staging, to: path, on: endpoint, replacing: true, isStaging: true)
        } catch {
            // Not committed, so whatever is left at the staging name is ours.
            _ = try? await perform(endpoint) { system in
                if try await system.unfollowedEntry(at: staging) != nil { try await system.removeFile(staging) }
            }
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
    func commit(_ item: String, to path: String, on endpoint: RemoteEndpoint, replacing: Bool, isStaging: Bool) async throws {
        var swap: PendingSwap?
        if replacing, try await read(endpoint, { try await $0.unfollowedEntry(at: path) }) != nil {
            swap = PendingSwap(endpoint: endpoint, path: path, backup: Self.sibling(of: path, suffix: "old"), staging: isStaging ? item : nil)
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
            if committed { return }
            throw error
        }
        if let swap { try? await settle(swap) }
    }

    /// Finishes a swap: restores the old item if the new one never arrived, otherwise deletes the backup;
    /// then deletes a leftover staging copy and forgets the swap.
    func settle(_ swap: PendingSwap) async throws {
        try await perform(swap.endpoint) { system in
            if let backup = try await system.unfollowedEntry(at: swap.backup) {
                if try await system.unfollowedEntry(at: swap.path) == nil {
                    try await system.rename(swap.backup, to: swap.path)
                } else {
                    try await system.removeRecursively(backup)
                }
            }
            if let staging = swap.staging, let entry = try await system.unfollowedEntry(at: staging) {
                try await system.removeRecursively(entry)
            }
        }
        journal.remove(swap)
    }

    /// Settles swaps a dropped connection or an earlier run left on `endpoint`. Runs on each new connection.
    func settleLeftoverSwaps(on endpoint: RemoteEndpoint) async {
        for swap in journal.swaps where swap.endpoint == endpoint && !swapsInFlight.contains(swap) {
            try? await settle(swap)
        }
    }

    /// ".name.foldera-1A2B3C4D.suffix" beside `path`.
    private static func sibling(of path: String, suffix: String) -> String {
        RemotePath.join(RemotePath.parent(of: path), ".\(RemotePath.name(of: path)).foldera-\(UUID().uuidString.prefix(8)).\(suffix)")
    }
}
