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
        let sourceEntry: RemoteEntry?
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
        var listings: [URL: [String: RemoteEntry]] = [:]
        for source in sources {
            let name = Self.name(of: source)
            let sameFolder = Self.parent(of: source) == directory
            if sameFolder && kind == .move { continue }
            let serverMove = kind == .move && source.isRemote && source.remoteEndpoint == directory.remoteEndpoint
            var entry: RemoteEntry?
            if !serverMove {
                let directoryLink: Bool
                if source.isRemote {
                    let metadata = try await sourceEntry(source, listings: &listings)
                    entry = metadata
                    directoryLink = metadata.isSymlink && metadata.isDirectory
                } else {
                    directoryLink = try isDirectoryLink(source)
                }
                if directoryLink {
                    if kind == .move {
                        throw RemoteError.failed(L10n.format("Foldera can’t move the linked folder “%@” between file systems.", name))
                    }
                    continue
                }
            }
            var job = Job(source: source, sourceEntry: entry, destination: Self.child(directory, name))
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
            for job in jobs where !isServerMove(kind, job) { total += try await size(of: job) }
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
                    // Local staging belongs to a private directory, so failed exclusive creation
                    // cannot make cleanup delete a colliding public path.
                    let localStaging = job.destination.isRemote ? nil : try FileManager.default.url(
                        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: job.destination, create: true)
                    let staging = if let localStaging { localStaging.appendingPathComponent("payload") } else { try await stagingURL(for: job.destination) }
                    defer { if let localStaging { try? FileManager.default.removeItem(at: localStaging) } }
                    do {
                        try await copy(job, to: staging, counter: counter, moving: kind == .move)
                        try await commit(staging, to: job.destination, replacing: job.replace, isStaging: true)
                    } catch {
                        if staging.isRemote { await discard(staging) }
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
                                                replacing: replacing, isStaging: isStaging,
                                                stagingDirectory: isStaging ? RemotePath.parent(of: item.remotePath) : nil)
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

    private func copy(_ job: Job, to destination: URL, counter: ByteCounter, moving: Bool) async throws {
        let source = job.source
        switch (source.isRemote, destination.isRemote) {
        case (false, true): try await upload(source, to: destination, counter: counter, moving: moving)
        case (true, false): try await download(job, to: destination, counter: counter, moving: moving)
        case (true, true):
            // Between servers, or a copy on one server: SFTP has no server-side copy, so go through a temporary folder.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Foldera-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let local = staging.appendingPathComponent(Self.name(of: source))
            try await download(job, to: local, counter: ByteCounter(progress: TransferProgress()), moving: moving)
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

    private func download(_ job: Job, to destination: URL, counter: ByteCounter, moving: Bool) async throws {
        let endpoint = try Self.endpoint(job.source)
        guard let entry = job.sourceEntry else {
            throw RemoteError.notFound(Self.name(of: job.source))
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

    /// One parent snapshot per server and folder, shared by planning, sizing and the initial download.
    private func sourceEntry(_ url: URL, listings: inout [URL: [String: RemoteEntry]]) async throws -> RemoteEntry {
        let endpoint = try Self.endpoint(url)
        let entry: RemoteEntry?
        if url.remotePath == "/" {
            entry = try await connections.read(endpoint) { try await $0.entry(at: "/") }
        } else {
            let parent = Self.parent(of: url)
            if listings[parent] == nil {
                let children = try await connections.read(endpoint) { try await $0.list(parent.remotePath) }
                listings[parent] = Dictionary(children.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
            }
            entry = listings[parent]?[url.remotePath]
        }
        guard let entry else { throw RemoteError.notFound(Self.name(of: url)) }
        return entry
    }

    private func isDirectoryLink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func exists(_ url: URL) async throws -> Bool {
        guard url.isRemote else { return FileOperations.exists(url) }
        return try await connections.read(try Self.endpoint(url)) { try await $0.entry(at: url.remotePath) } != nil
    }

    private func size(of job: Job) async throws -> Int64 {
        guard job.source.isRemote else { return CopyEngine.size(of: job.source) }
        guard let entry = job.sourceEntry else { throw RemoteError.notFound(Self.name(of: job.source)) }
        return try await connections.read(try Self.endpoint(job.source)) { try await $0.totalSize(entry) }
    }

    /// A payload inside an exclusively acquired private directory beside `destination` on its server.
    func stagingURL(for destination: URL) async throws -> URL {
        let endpoint = try Self.endpoint(destination)
        let directory = try await connections.reserveTemporaryDirectory(beside: destination.remotePath, suffix: "part", on: endpoint)
        return endpoint.url(path: RemotePath.join(directory, "payload"))
    }

    /// Deletes a staging copy (never to the Trash). Best effort: the transfer's own error is what matters.
    private func discard(_ url: URL) async {
        if url.isRemote {
            try? await connections.discardTemporaryDirectory(RemotePath.parent(of: url.remotePath), on: Self.endpoint(url))
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
        return FileOperations.contains(source, directory)
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
