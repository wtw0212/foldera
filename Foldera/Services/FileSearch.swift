import Foundation
import UniformTypeIdentifiers

/// Recursive file name search under a folder, like Explorer's search box.
nonisolated enum FileSearch {
    enum Scope: String, CaseIterable, Sendable {
        case folder, subfolders
        @MainActor var title: String { L10n.text(self == .folder ? "This folder" : "Subfolders") }
    }

    struct Filters: Equatable, Sendable {
        enum Kind: String, CaseIterable, Sendable {
            case any, folders, documents, images, audio, video, archives, applications
            @MainActor var title: String {
                let key = switch self {
                case .any: "Any type"
                case .folders: "Folders"
                case .documents: "Documents"
                case .images: "Images"
                case .audio: "Audio"
                case .video: "Video"
                case .archives: "Archives"
                case .applications: "Applications"
                }
                return L10n.text(key)
            }
        }

        enum Modified: String, CaseIterable, Sendable {
            case any, today, week, month
            @MainActor var title: String {
                let key = switch self {
                case .any: "Any date"
                case .today: "Today"
                case .week: "Last 7 days"
                case .month: "Last 30 days"
                }
                return L10n.text(key)
            }
        }

        enum Size: String, CaseIterable, Sendable {
            case any, small, medium, large
            @MainActor var title: String {
                let key = switch self {
                case .any: "Any size"
                case .small: "Under 1 MB"
                case .medium: "1–100 MB"
                case .large: "100 MB or more"
                }
                return L10n.text(key)
            }
        }

        var kind: Kind = .any
        var modified: Modified = .any
        var size: Size = .any
        var isEmpty: Bool { self == Filters() }

        func matches(_ item: FileItem, now: Date = Date()) -> Bool {
            let type = item.contentType ?? UTType(filenameExtension: item.url.pathExtension)
            let matchesKind = switch kind {
            case .any: true
            case .folders: item.isNavigable
            case .documents: type?.conforms(to: .text) == true || type?.conforms(to: .pdf) == true || type?.conforms(to: .compositeContent) == true
            case .images: type?.conforms(to: .image) == true
            case .audio: type?.conforms(to: .audio) == true
            case .video: type?.conforms(to: .movie) == true
            case .archives: type?.conforms(to: .archive) == true
            case .applications: type?.conforms(to: .applicationBundle) == true || type?.conforms(to: .executable) == true
            }
            guard matchesKind else { return false }
            if modified != .any {
                let days = modified == .week ? 7 : 30
                let cutoff = modified == .today ? Calendar.current.startOfDay(for: now) : now.addingTimeInterval(-Double(days) * 86_400)
                guard let date = item.dateModified, date >= cutoff else { return false }
            }
            guard size != .any else { return true }
            guard let bytes = item.size else { return false }
            return switch size {
            case .any: true
            case .small: bytes < 1_000_000
            case .medium: bytes >= 1_000_000 && bytes < 100_000_000
            case .large: bytes >= 100_000_000
            }
        }
    }

    /// Stops collecting after this many matches so huge trees stay responsive.
    static let maxResults = 10_000

    /// Streams matches in batches. Cancelling the consuming task stops the walk.
    static func run(in root: URL, query: String, includeHidden: Bool, scope: Scope = .subfolders, filters: Filters = Filters()) -> AsyncStream<[FileItem]> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                walk(root: root, matcher: Matcher(query), includeHidden: includeHidden, scope: scope, filters: filters) { batch in
                    continuation.yield(batch)
                    return !Task.isCancelled
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synchronous walk; `emit` returns false to stop early.
    private static func walk(root: URL, matcher: Matcher, includeHidden: Bool, scope: Scope, filters: Filters, emit: ([FileItem]) -> Bool) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        if scope == .folder { options.insert(.skipsSubdirectoryDescendants) }
        // Only matches need their details (read by `FileItem`); prefetching them for every file walked
        // would slow the search down for no benefit.
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [],
            options: options,
            errorHandler: { _, _ in true } // skip unreadable folders and keep going
        ) else { return }

        var batch: [FileItem] = []
        var found = 0
        let now = Date()
        var lastFlush = ContinuousClock.now
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return }
            guard matcher.matches(url.lastPathComponent) else { continue }
            let item = FileItem(url: url)
            guard filters.matches(item, now: now) else { continue }
            batch.append(item)
            found += 1
            if found >= maxResults { break }
            // Every batch re-sorts what is shown, so send few large batches rather than many small ones.
            if batch.count >= 1_000 || ContinuousClock.now - lastFlush > .milliseconds(200) {
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
            if text.isEmpty { return true }
            if let pattern { return pattern.evaluate(with: name) }
            return name.localizedStandardContains(text)
        }
    }
}
