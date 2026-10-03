import AppKit

/// Copies and moves that involve an SFTP server: uploads, downloads and server-side moves,
/// shown in the same progress window as local transfers.
struct RemoteTransfers {
    let transfers: FileTransfers
    var connections: RemoteConnections = .shared
    var conflicts: (FileTransfer.Kind, URL) -> ConflictResolver = { ConflictResolver(kind: $0, destination: $1) }
    var alert: (String, String) -> Void = { FileTransfers.alert($0, detail: $1) }

    private struct Job {
        let source: URL
        var destination: URL
        var replace = false
    }

    func run(_ kind: FileTransfer.Kind, _ sources: [URL], into directory: URL) async -> TransferResult {
        let directory = directory.normalizedFileURL
        let sources = sources.map(\.normalizedFileURL)
        if let source = sources.first(where: { Self.contains($0, directory) }) {
            alert(
                L10n.text("The destination folder is a subfolder of the source folder."),
                L10n.format(kind == .copy ? "“%@” can’t be copied into itself." : "“%@” can’t be moved into itself.", Self.name(of: source))
            )
            return TransferResult()
        }
        do {
            let jobs = try await plan(kind, sources, into: directory)
            guard !jobs.isEmpty else { return TransferResult() }
            return await execute(kind, jobs, from: sources[0], into: directory)
        } catch is CopyEngine.Cancelled {
            return TransferResult(error: CopyEngine.Cancelled())
        } catch is CancellationError {
            return TransferResult(error: CopyEngine.Cancelled())
        } catch {
            BrowserTab.present(error)
            return TransferResult(error: error)
        }
    }

    /// Picks destination names and asks about conflicts, like a local transfer.
    private func plan(_ kind: FileTransfer.Kind, _ sources: [URL], into directory: URL) async throws -> [Job] {
        let resolver = conflicts(kind, directory)
        var jobs: [Job] = []
        for source in sources {
            let name = Self.name(of: source)
            let sameFolder = Self.parent(of: source) == directory
            if sameFolder && kind == .move { continue }
            let serverMove = kind == .move && source.isRemote && source.remoteEndpoint == directory.remoteEndpoint
            if !serverMove, try await isDirectoryLink(source) {
                if kind == .move {
                    throw RemoteError.failed(L10n.format("Foldera can’t move the linked folder “%@” between file systems.", name))
                }
                continue
            }
            var job = Job(source: source, destination: Self.child(directory, name))
            if sameFolder {
                job.destination = try await uniqueURL(named: name, in: directory, copySuffix: true)
            } else if try await exists(job.destination) {
                switch resolver.resolve(name: name, remaining: sources.count) {
                case .replace: job.replace = true
                case .keepBoth: job.destination = try await uniqueURL(named: name, in: directory, copySuffix: false)
                case .skip: continue
                case .cancel: throw CopyEngine.Cancelled()
                }
            }
            jobs.append(job)
        }
        return jobs
    }

    private func execute(_ kind: FileTransfer.Kind, _ jobs: [Job], from first: URL, into directory: URL) async -> TransferResult {
        let transfer = FileTransfer(kind: kind, itemCount: jobs.count, source: Self.parent(of: first), destination: directory)
        transfers.begin(transfer)
        defer { transfers.end(transfer) }
        let progress = transfer.progress
        let ticker = Task {
            while !Task.isCancelled {
                transfer.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { ticker.cancel() }

        var result = TransferResult()
        do {
            var total: Int64 = 0
            for job in jobs where !isServerMove(kind, job) { total += try await size(of: job.source) }
            transfer.totalBytes = total
            let counter = ByteCounter(progress: progress)
            for job in jobs {
                if progress.isCancelled { throw CopyEngine.Cancelled() }
                progress.setCurrentName(Self.name(of: job.source))
                let serverMove = isServerMove(kind, job)
                if serverMove {
                    try await commit(job.source, to: job.destination, replacing: job.replace, isStaging: false)
                } else {
                    // Copy under a hidden temporary name, then swap it into place. A failed or cancelled transfer
                    // leaves no partial item, and a replaced item is only removed once the new one is in place.
                    let staging = Self.stagingURL(for: job.destination)
                    do {
                        try await copy(job.source, to: staging, counter: counter, moving: kind == .move)
                        try await commit(staging, to: job.destination, replacing: job.replace, isStaging: true)
                    } catch {
                        await discard(staging)
                        throw error
                    }
                }
                result.results.append(job.destination)
                if kind == .move {
                    result.consumedCutSources.append(job.source)
                    if !serverMove { try await remove(job.source) }
                    result.completedSources.append(job.source)
                }
            }
        } catch {
            result.error = error
            if !(error is CopyEngine.Cancelled) { BrowserTab.present(error) }
        }
        transfer.refresh()
        // Server folders aren't watched: tell tabs showing the destination (and a move's sources) to reload.
        let changed = Set([directory] + (kind == .move ? jobs.map { Self.parent(of: $0.source) } : []))
        for folder in changed where folder.isRemote {
            NotificationCenter.default.post(name: .remoteFolderChanged, object: nil, userInfo: ["url": folder])
        }
        return result
    }

    /// Moves `item` to `destination`, replacing what's there without ever losing it: see
    /// `RemoteConnections.commit`. Locally the replaced item goes to the Trash, and comes back if the move fails.
    private func commit(_ item: URL, to destination: URL, replacing: Bool, isStaging: Bool) async throws {
        if destination.isRemote {
            return try await connections.commit(item.remotePath, to: destination.remotePath, on: try Self.endpoint(destination),
                                                replacing: replacing, isStaging: isStaging)
        }
        guard replacing, FileOperations.exists(destination) else {
            return try FileManager.default.moveItem(at: item, to: destination)
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: destination, resultingItemURL: &trashed)
        do {
            try FileManager.default.moveItem(at: item, to: destination)
        } catch {
            if let trashed { try? FileManager.default.moveItem(at: trashed as URL, to: destination) }
            throw error
        }
    }

    /// A move within one server is a rename; nothing is downloaded.
    private func isServerMove(_ kind: FileTransfer.Kind, _ job: Job) -> Bool {
        kind == .move && job.source.isRemote && job.source.remoteEndpoint == job.destination.remoteEndpoint
    }

    // MARK: Copying

    private func copy(_ source: URL, to destination: URL, counter: ByteCounter, moving: Bool) async throws {
        switch (source.isRemote, destination.isRemote) {
        case (false, true): try await upload(source, to: destination, counter: counter, moving: moving)
        case (true, false): try await download(source, to: destination, counter: counter, moving: moving)
        case (true, true):
            // Between servers, or a copy on one server: SFTP has no server-side copy, so go through a temporary folder.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Foldera-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let local = staging.appendingPathComponent(Self.name(of: source))
            try await download(source, to: local, counter: ByteCounter(progress: TransferProgress()), moving: moving)
            try await upload(local, to: destination, counter: counter, moving: moving)
        case (false, false):
            try CopyEngine.copy(source, to: destination, progress: counter.progress, baseBytes: counter.total)
        }
    }

    private func upload(_ source: URL, to destination: URL, counter: ByteCounter, moving: Bool) async throws {
        let endpoint = try Self.endpoint(destination)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true, (try? source.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if moving {
                throw RemoteError.failed(L10n.format("Foldera can’t move the linked folder “%@” between file systems.", Self.name(of: source)))
            }
            return // Linked folders aren't followed, so a link loop can't upload forever.
        }
        if values.isDirectory == true {
            try await connections.perform(endpoint) { try await $0.makeDirectory(destination.remotePath) }
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for child in children {
                try await upload(child, to: Self.child(destination, child.lastPathComponent), counter: counter, moving: moving)
            }
        } else {
            try await connections.perform(endpoint) { try await $0.upload(source, to: destination.remotePath, written: counter.add) }
        }
    }

    private func download(_ source: URL, to destination: URL, counter: ByteCounter, moving: Bool) async throws {
        let endpoint = try Self.endpoint(source)
        guard let entry = try await connections.read(endpoint, { try await $0.unfollowedEntry(at: source.remotePath) }) else {
            throw RemoteError.notFound(Self.name(of: source))
        }
        try await download(entry, from: endpoint, to: destination, counter: counter, moving: moving)
    }

    private func download(_ entry: RemoteEntry, from endpoint: RemoteEndpoint, to destination: URL, counter: ByteCounter, moving: Bool) async throws {
        if entry.isSymlink && entry.isDirectory {
            if moving {
                throw RemoteError.failed(L10n.format("Foldera can’t move the linked folder “%@” between file systems.", entry.name))
            }
            return
        }
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let children = try await connections.read(endpoint) { try await $0.list(entry.path) }
            for child in children {
                try await download(child, from: endpoint, to: destination.appendingPathComponent(child.name), counter: counter, moving: moving)
            }
        } else {
            try await connections.perform(endpoint) { try await $0.download(entry.path, to: destination, written: counter.add) }
        }
    }

    // MARK: Local and remote helpers

    private func isDirectoryLink(_ url: URL) async throws -> Bool {
        if url.isRemote {
            guard let entry = try await connections.read(try Self.endpoint(url), { try await $0.unfollowedEntry(at: url.remotePath) }) else {
                throw RemoteError.notFound(Self.name(of: url))
            }
            return entry.isSymlink && entry.isDirectory
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func exists(_ url: URL) async throws -> Bool {
        guard url.isRemote else { return FileOperations.exists(url) }
        return try await connections.read(try Self.endpoint(url)) { try await $0.entry(at: url.remotePath) } != nil
    }

    private func size(of url: URL) async throws -> Int64 {
        guard url.isRemote else { return CopyEngine.size(of: url) }
        return try await connections.read(try Self.endpoint(url)) { system in
            guard let entry = try await system.unfollowedEntry(at: url.remotePath) else { return 0 }
            return try await system.totalSize(entry)
        }
    }

    /// ".name.foldera-1A2B3C4D.part" beside `destination`.
    static func stagingURL(for destination: URL) -> URL {
        child(parent(of: destination), ".\(name(of: destination)).foldera-\(UUID().uuidString.prefix(8)).part")
    }

    /// Deletes a staging copy (never to the Trash). Best effort: the transfer's own error is what matters.
    private func discard(_ url: URL) async {
        if url.isRemote {
            _ = try? await connections.perform(try Self.endpoint(url)) { system in
                if let entry = try await system.unfollowedEntry(at: url.remotePath) { try await system.removeRecursively(entry) }
            }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Server items are deleted for good; local ones go to the Trash.
    private func remove(_ url: URL) async throws {
        if url.isRemote {
            try await connections.perform(try Self.endpoint(url)) { system in
                if let entry = try await system.unfollowedEntry(at: url.remotePath) { try await system.removeRecursively(entry) }
            }
        } else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func uniqueURL(named name: String, in directory: URL, copySuffix: Bool) async throws -> URL {
        guard let endpoint = directory.remoteEndpoint else {
            return FileOperations.uniqueURL(named: name, in: directory, copySuffix: copySuffix)
        }
        let path = try await connections.read(endpoint) { try await $0.uniquePath(named: name, in: directory.remotePath, copySuffix: copySuffix) }
        return endpoint.url(path: path)
    }

    private static func endpoint(_ url: URL) throws -> RemoteEndpoint {
        guard let endpoint = url.remoteEndpoint else { throw RemoteError.failed(L10n.text("This address is missing a user name.")) }
        return endpoint
    }

    static func name(of url: URL) -> String { url.isRemote ? RemotePath.name(of: url.remotePath) : url.lastPathComponent }

    static func parent(of url: URL) -> URL {
        guard let endpoint = url.remoteEndpoint else { return url.deletingLastPathComponent().normalizedFileURL }
        return endpoint.url(path: RemotePath.parent(of: url.remotePath))
    }

    static func child(_ directory: URL, _ name: String) -> URL {
        guard let endpoint = directory.remoteEndpoint else { return directory.appendingPathComponent(name) }
        return endpoint.url(path: RemotePath.join(directory.remotePath, name))
    }

    /// True when `directory` is `source` or inside it, on the same machine.
    static func contains(_ source: URL, _ directory: URL) -> Bool {
        guard source.isRemote == directory.isRemote else { return false }
        if source.isRemote {
            return source.remoteEndpoint == directory.remoteEndpoint && RemotePath.isWithin(directory.remotePath, source.remotePath)
        }
        return directory.path == source.path || directory.path.hasPrefix(source.path + "/")
    }
}

/// Running byte count for one transfer; throws to stop when the user cancels.
nonisolated final class ByteCounter: @unchecked Sendable {
    let progress: TransferProgress
    private let lock = NSLock()
    private var bytes: Int64 = 0

    init(progress: TransferProgress) { self.progress = progress }

    var total: Int64 { lock.withLock { bytes } }

    @Sendable func add(_ count: Int) throws {
        let total = lock.withLock {
            bytes += Int64(count)
            return bytes
        }
        progress.setCompleted(total)
        if progress.isCancelled { throw CopyEngine.Cancelled() }
    }
}
