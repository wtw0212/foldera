import AppKit

/// File system mutations. Long-running work runs off the main actor.
nonisolated enum FileOperations {
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
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains(":") else {
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

    static func trash(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
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
