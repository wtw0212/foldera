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
                if isServerMove(kind, job) {
                    // SFTP renames can't overwrite, so a replaced item goes first; the rename itself is atomic.
                    if job.replace { try await remove(job.destination) }
                    try await connections.perform(try Self.endpoint(job.source)) { try await $0.rename(job.source.remotePath, to: job.destination.remotePath) }
                } else {
                    // Copy under a hidden temporary name, and only then replace and rename into place. A failed
                    // or cancelled transfer leaves no partial item, and a replaced item survives until the copy is complete.
                    let staging = Self.stagingURL(for: job.destination)
                    do {
                        try await copy(job.source, to: staging, counter: counter)
                    } catch {
                        await discard(staging)
                        throw error
                    }
                    if job.replace { try await remove(job.destination) }
                    try await move(staging, to: job.destination)
                    if kind == .move { try await remove(job.source) }
                }
                result.results.append(job.destination)
            }
        } catch {
            result.error = error
            if !(error is CopyEngine.Cancelled) { BrowserTab.present(error) }
        }
        transfer.refresh()
        return result
    }

    /// A move within one server is a rename; nothing is downloaded.
    private func isServerMove(_ kind: FileTransfer.Kind, _ job: Job) -> Bool {
        kind == .move && job.source.isRemote && job.source.remoteEndpoint == job.destination.remoteEndpoint
    }

    // MARK: Copying

    private func copy(_ source: URL, to destination: URL, counter: ByteCounter) async throws {
        switch (source.isRemote, destination.isRemote) {
        case (false, true): try await upload(source, to: destination, counter: counter)
        case (true, false): try await download(source, to: destination, counter: counter)
        case (true, true):
            // Between servers, or a copy on one server: SFTP has no server-side copy, so go through a temporary folder.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Foldera-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let local = staging.appendingPathComponent(Self.name(of: source))
            try await download(source, to: local, counter: ByteCounter(progress: TransferProgress()))
            try await upload(local, to: destination, counter: counter)
        case (false, false):
            try CopyEngine.copy(source, to: destination, progress: counter.progress, baseBytes: counter.total)
        }
    }

    private func upload(_ source: URL, to destination: URL, counter: ByteCounter) async throws {
        let endpoint = try Self.endpoint(destination)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true, (try? source.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return // Linked folders aren't followed, so a link loop can't upload forever.
        }
        if values.isDirectory == true {
            try await connections.perform(endpoint) { try await $0.makeDirectory(destination.remotePath) }
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for child in children {
                try await upload(child, to: Self.child(destination, child.lastPathComponent), counter: counter)
            }
        } else {
            try await connections.perform(endpoint) { try await $0.upload(source, to: destination.remotePath, written: counter.add) }
        }
    }

    private func download(_ source: URL, to destination: URL, counter: ByteCounter) async throws {
        let endpoint = try Self.endpoint(source)
        guard let entry = try await connections.read(endpoint, { try await $0.entry(at: source.remotePath) }) else {
            throw RemoteError.notFound(Self.name(of: source))
        }
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let children = try await connections.read(endpoint) { try await $0.list(source.remotePath) }
            for child in children where !(child.isSymlink && child.isDirectory) {
                try await download(endpoint.url(path: child.path), to: destination.appendingPathComponent(child.name), counter: counter)
            }
        } else {
            try await connections.perform(endpoint) { try await $0.download(source.remotePath, to: destination, written: counter.add) }
        }
    }

    // MARK: Local and remote helpers

    private func exists(_ url: URL) async throws -> Bool {
        guard url.isRemote else { return FileOperations.exists(url) }
        return try await connections.read(try Self.endpoint(url)) { try await $0.entry(at: url.remotePath) } != nil
    }

    private func size(of url: URL) async throws -> Int64 {
        guard url.isRemote else { return CopyEngine.size(of: url) }
        return try await connections.read(try Self.endpoint(url)) { system in
            guard let entry = try await system.entry(at: url.remotePath) else { return 0 }
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

    private func move(_ source: URL, to destination: URL) async throws {
        if source.isRemote {
            try await connections.perform(try Self.endpoint(source)) { try await $0.rename(source.remotePath, to: destination.remotePath) }
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
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
