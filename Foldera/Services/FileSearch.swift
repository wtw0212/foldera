import Foundation

/// Recursive file name search under a folder, like Explorer's search box.
nonisolated enum FileSearch {
    /// Stops collecting after this many matches so huge trees stay responsive.
    static let maxResults = 10_000

    /// Streams matches in batches. Cancelling the consuming task stops the walk.
    static func run(in root: URL, query: String, includeHidden: Bool) -> AsyncStream<[FileItem]> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                walk(root: root, matcher: Matcher(query), includeHidden: includeHidden) { batch in
                    continuation.yield(batch)
                    return !Task.isCancelled
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synchronous walk; `emit` returns false to stop early.
    private static func walk(root: URL, matcher: Matcher, includeHidden: Bool, emit: ([FileItem]) -> Bool) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: options,
            errorHandler: { _, _ in true } // skip unreadable folders and keep going
        ) else { return }

        var batch: [FileItem] = []
        var found = 0
        var lastFlush = ContinuousClock.now
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return }
            guard matcher.matches(url.lastPathComponent) else { continue }
            batch.append(FileItem(url: url))
            found += 1
            if found >= maxResults { break }
            if batch.count >= 200 || ContinuousClock.now - lastFlush > .milliseconds(150) {
                guard emit(batch) else { return }
                batch.removeAll(keepingCapacity: true)
                lastFlush = .now
            }
        }
        if !batch.isEmpty { _ = emit(batch) }
    }

    /// Plain text matches anywhere in the name; `*` and `?` work as wildcards (e.g. `*.pdf`).
    struct Matcher {
        private let text: String
        private let pattern: NSPredicate?

        init(_ query: String) {
            text = query.trimmingCharacters(in: .whitespaces)
            pattern = text.contains("*") || text.contains("?")
                ? NSPredicate(format: "SELF LIKE[cd] %@", text)
                : nil
        }

        func matches(_ name: String) -> Bool {
            if let pattern { return pattern.evaluate(with: name) }
            return name.localizedStandardContains(text)
        }
    }
}
