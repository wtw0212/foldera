import AppKit
import Darwin

/// File system mutations. Long-running work runs off the main actor.
nonisolated enum FileOperations {
    /// Includes dangling symlinks, which fileExists(atPath:) follows and misses.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Moves without replacing a racing destination; reports a surviving copy if deletion fails.
    static func moveItem(_ source: URL, to destination: URL, progress: TransferProgress = TransferProgress(), baseBytes: Int64 = 0, allowRename: Bool = true) throws {
        guard source.isFileURL, destination.isFileURL, !source.path.isEmpty, !destination.path.isEmpty,
              !source.path(percentEncoded: false).contains("\0"), !destination.path(percentEncoded: false).contains("\0") else {
            throw OperationError.invalidName(destination.lastPathComponent)
        }
        if allowRename, try renameExclusively(source, to: destination) { return }
        try CopyEngine.copy(source, to: destination, progress: progress, baseBytes: baseBytes)
        do {
            if progress.isCancelled { throw CopyEngine.Cancelled() }
            // Recursive removal may partially succeed, so keep the complete destination on failure.
            try FileManager.default.removeItem(at: source)
        } catch {
            throw FileChange.Failure(cause: error, remaining: .created([destination]), sourceRemovalFailed: true)
        }
    }

    /// Returns false when a copy is needed. Never falls back to a check followed by plain rename.
    static func renameExclusively(_ source: URL, to destination: URL) throws -> Bool {
        let parent = destination.deletingLastPathComponent()
        guard sameVolume(source, parent),
              (try? parent.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == true else { return false }
        if renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let code = errno
        if code == ENOTSUP { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    enum OperationError: LocalizedError {
        case invalidName(String)
        case alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name): "“\(name)” is not a valid file name."
            case .alreadyExists(let name): "An item named “\(name)” already exists in this location."
            }
        }
    }

    static func newFolder(in directory: URL) throws -> URL {
        let destination = uniqueURL(named: "New folder", in: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    static func newTextDocument(in directory: URL) throws -> URL {
        let destination = uniqueURL(named: "New Text Document.txt", in: directory)
        guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        return destination
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\0") else {
            throw OperationError.invalidName(newName)
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if destination == url { return url }
        // Allow case-only renames on case-insensitive volumes.
        let caseOnly = destination.path.lowercased() == url.path.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: destination.path) {
            throw OperationError.alreadyExists(trimmed)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Moves items to the Trash and returns where each one went, for undo.
    @discardableResult
    static func trash(_ urls: [URL]) throws -> [(original: URL, trashed: URL)] {
        var pairs: [(original: URL, trashed: URL)] = []
        do {
            for url in urls {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed { pairs.append((url, trashed as URL)) }
            }
            return pairs
        } catch {
            throw FileChange.Failure(cause: error, remaining: .trashed(pairs))
        }
    }

    /// Copies items into `directory`, naming duplicates "name - Copy" like Explorer. Returns the new URLs.
    static func copy(_ urls: [URL], into directory: URL) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            try urls.map { source in
                let destination = uniqueURL(named: source.lastPathComponent, in: directory, copySuffix: true)
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            }
        }.value
    }

    /// Moves items into `directory`. Items already there are left alone. Returns the new URLs.
    static func move(_ urls: [URL], into directory: URL) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            try urls.map { source in
                if source.deletingLastPathComponent().normalizedFileURL == directory.normalizedFileURL {
                    return source
                }
                let destination = uniqueURL(named: source.lastPathComponent, in: directory)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            }
        }.value
    }

    /// Returns a free URL for `name` in `directory`: "name (2)", or "name - Copy", "name - Copy (2)" when `copySuffix` is set.
    static func uniqueURL(named name: String, in directory: URL, copySuffix: Bool = false) -> URL {
        let fileManager = FileManager.default
        let candidate = directory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: candidate.path) { return candidate }

        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func make(_ base: String) -> URL {
            directory.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        }
        let base = copySuffix ? "\(stem) - Copy" : stem
        if copySuffix, !fileManager.fileExists(atPath: make(base).path) { return make(base) }
        var index = 2
        while fileManager.fileExists(atPath: make("\(base) (\(index))").path) { index += 1 }
        return make("\(base) (\(index))")
    }
}
