import AppKit
import Darwin

/// File system mutations. Long-running work runs off the main actor.
nonisolated enum FileOperations {
    /// Includes dangling symlinks, which fileExists(atPath:) follows and misses.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Creates a new regular file without replacing a file, directory or dangling symlink.
    static func createFileExclusively(at url: URL) throws -> FileHandle {
        guard url.isFileURL, !url.path.isEmpty, !url.path(percentEncoded: false).contains("\0") else {
            throw OperationError.invalidName(url.lastPathComponent)
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Only source directories contain destinations; source symlinks are copied as links.
    /// Compares directory locations, including symlinked parents and filesystem aliases.
    static func contains(_ source: URL, _ directory: URL) -> Bool {
        guard source.isFileURL, directory.isFileURL else { return false }
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFDIR else { return false }
        var ancestor = directory.resolvingSymlinksInPath().standardizedFileURL
        while true {
            var info = stat()
            if stat(ancestor.path, &info) == 0, info.st_dev == sourceInfo.st_dev, info.st_ino == sourceInfo.st_ino { return true }
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            if parent.path == ancestor.path { return false }
            ancestor = parent
        }
    }

    static func rejectCopyIntoSource(_ source: URL, to destination: URL) throws {
        var info = stat()
        // Copying a symlink copies the link itself; only an actual source directory is traversed.
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        if contains(source, destination.deletingLastPathComponent()) {
            throw OperationError.invalidDestination(destination.path)
        }
    }

    /// Moves without replacing a racing destination; reports a surviving copy if deletion fails.
    static func moveItem(_ source: URL, to destination: URL, progress: TransferProgress = TransferProgress(), baseBytes: Int64 = 0, allowRename: Bool = true, fileManager: FileManager = .default) throws {
        guard source.isFileURL, destination.isFileURL, !source.path.isEmpty, !destination.path.isEmpty,
              !source.path(percentEncoded: false).contains("\0"), !destination.path(percentEncoded: false).contains("\0") else {
            throw OperationError.invalidName(destination.lastPathComponent)
        }
        try rejectCopyIntoSource(source, to: destination)
        if allowRename, try renameExclusively(source, to: destination) { return }
        try CopyEngine.copy(source, to: destination, progress: progress, baseBytes: baseBytes)
        do {
            if progress.isCancelled { throw CopyEngine.Cancelled() }
            // Recursive removal may partially succeed, so keep the complete destination on failure.
            try fileManager.removeItem(at: source)
        } catch {
            throw FileChange.Failure(cause: error, remaining: .moveCleanupPending(source: source, completeCopy: destination))
        }
    }

    /// Returns false when a copy is needed. Never falls back to a check followed by plain rename.
    static func renameExclusively(_ source: URL, to destination: URL) throws -> Bool {
        guard canRename(source, to: destination) else { return false }
        if renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let code = errno
        if code == ENOTSUP { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func supportsExclusiveRename(in directory: URL) -> Bool {
        (try? directory.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == true
    }

    static func canRename(_ source: URL, to destination: URL) -> Bool {
        let parent = destination.deletingLastPathComponent()
        return sameVolume(source, parent) && supportsExclusiveRename(in: parent)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    enum OperationError: LocalizedError, Equatable {
        case invalidName(String)
        case alreadyExists(String)
        case invalidDestination(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name): L10n.format("“%@” is not a valid file name.", language: .saved, arguments: [name])
            case .alreadyExists(let name): L10n.format("An item named “%@” already exists in this location.", language: .saved, arguments: [name])
            case .invalidDestination: L10n.text("The destination folder is a subfolder of the source folder.", language: .saved)
            }
        }
    }

    static func newFolder(in directory: URL) throws -> URL {
        let destination = uniqueURL(named: "New folder", in: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    static func newTextDocument(in directory: URL) throws -> URL {
        var index = 1
        while true {
            let name = index == 1 ? "New Text Document.txt" : "New Text Document (\(index)).txt"
            let destination = directory.appendingPathComponent(name)
            do {
                let handle = try createFileExclusively(at: destination)
                try handle.close()
                return destination
            } catch let error as POSIXError where error.code == .EEXIST {
                index += 1
            }
        }
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
                try rejectCopyIntoSource(source, to: destination)
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
                try rejectCopyIntoSource(source, to: destination)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            }
        }.value
    }

    /// Returns a free URL for `name` in `directory`: "name (2)", or "name - Copy", "name - Copy (2)" when `copySuffix` is set.
    static func uniqueURL(named name: String, in directory: URL, copySuffix: Bool = false) -> URL {
        let candidate = directory.appendingPathComponent(name)
        if !exists(candidate) { return candidate }

        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func make(_ base: String) -> URL {
            directory.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        }
        let base = copySuffix ? "\(stem) - Copy" : stem
        if copySuffix, !exists(make(base)) { return make(base) }
        var index = 2
        while exists(make("\(base) (\(index))")) { index += 1 }
        return make("\(base) (\(index))")
    }
}
