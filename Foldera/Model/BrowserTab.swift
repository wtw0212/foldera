import AppKit
import Observation

enum SortField: String, CaseIterable, Identifiable {
    case name, dateModified, kind, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: L10n.text("Name")
        case .dateModified: L10n.text("Date modified")
        case .kind: L10n.text("Type")
        case .size: L10n.text("Size")
        }
    }
}

struct SortOrder: Equatable {
    var field: SortField = .name
    var ascending = true
}

/// One explorer tab: its location, history, listing and selection.
@Observable
final class BrowserTab: Identifiable {
    struct RenameRequest: Equatable {
        let url: URL
        let id = UUID()
    }

    /// The "This Mac" page (drives and their free space), like Explorer's This PC.
    static let thisMacURL = URL(string: "foldera:this-mac")!

    let id = UUID()
    private(set) var url: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private var lastLoadError: NSError?
    var loadError: String? { lastLoadError.map(Self.describe) }
    var selection: Set<URL> = []
    var sort = SortOrder()
    /// Layout for this folder; remembered per folder.
    var viewMode: ViewMode {
        didSet { if viewMode != oldValue { FolderViewModes.set(viewMode, for: url) } }
    }
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    /// Matches from the recursive search while the search box has text.
    private(set) var searchResults: [FileItem] = []
    private(set) var isSearching = false
    /// Set to start inline rename of an item once it appears in the list.
    var renameRequest: RenameRequest?
    /// Items for the "Rename N items" sheet, set when renaming a multiple selection.
    var bulkRenameItems: [FileItem]?
    /// Bumped to move keyboard focus to the file list.
    private(set) var focusListToken = 0

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var visibleCache: (key: VisibleKey, items: [FileItem])?
    private var itemsVersion = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private let settings = AppSettings.shared

    init(url: URL) {
        let url = url.normalizedFileURL
        self.url = url
        self.viewMode = FolderViewModes.mode(for: url)
        load(selecting: [])
    }

    // MARK: Derived state

    var title: String { Self.displayName(of: url) }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isThisMac: Bool { url == Self.thisMacURL }
    var canGoUp: Bool { parentURL != nil }

    /// The enclosing folder; a drive's root goes up to This Mac.
    var parentURL: URL? {
        if isThisMac { return nil }
        if url.path == "/" || (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true { return Self.thisMacURL }
        return url.deletingLastPathComponent()
    }
    var backHistory: [URL] { backStack.reversed() }
    var forwardHistory: [URL] { forwardStack.reversed() }

    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedItems: [FileItem] { visibleItems.filter { selection.contains($0.url) } }

    private struct VisibleKey: Equatable {
        let version: Int
        let sort: SortOrder
        let search: String
        let showHidden: Bool
    }

    /// The filtered and sorted listing shown in the file list. Folders always come first, like Explorer.
    var visibleItems: [FileItem] {
        let key = VisibleKey(version: itemsVersion, sort: sort, search: searchText, showHidden: settings.showHiddenFiles)
        if let visibleCache, visibleCache.key == key { return visibleCache.items }

        let source = isSearchActive ? searchResults : items
        var result = key.showHidden ? source : source.filter { !$0.isHidden }
        let sort = key.sort
        result.sort { a, b in
            if a.isNavigable != b.isNavigable { return a.isNavigable }
            let order: ComparisonResult = switch sort.field {
            case .name: a.name.localizedStandardCompare(b.name)
            case .dateModified: Self.compare(a.dateModified ?? .distantPast, b.dateModified ?? .distantPast)
            case .kind: a.kind.localizedStandardCompare(b.kind)
            case .size: Self.compare(a.size ?? -1, b.size ?? -1)
            }
            let resolved = order == .orderedSame ? a.name.localizedStandardCompare(b.name) : order
            return sort.ascending ? resolved == .orderedAscending : resolved == .orderedDescending
        }
        visibleCache = (key, result)
        return result
    }

    // MARK: Navigation

    func navigate(to destination: URL) {
        navigate(to: destination, selecting: [])
    }

    private func navigate(to destination: URL, selecting: Set<URL>) {
        let destination = destination.normalizedFileURL
        guard destination != url else { return }
        backStack.append(url)
        forwardStack.removeAll()
        move(to: destination, selecting: selecting)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        move(to: previous, selecting: [url])
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        move(to: next, selecting: [])
    }

    /// Jumps to an entry from the back/forward history menus.
    func jump(toHistory target: URL, back: Bool) {
        if back {
            while let previous = backStack.popLast() {
                forwardStack.append(url)
                url = previous
                if previous == target { break }
            }
        } else {
            while let next = forwardStack.popLast() {
                backStack.append(url)
                url = next
                if next == target { break }
            }
        }
        move(to: url, selecting: [])
    }

    func goUp() {
        guard let parentURL else { return }
        navigate(to: parentURL, selecting: [url])
    }

    func reload() {
        load(selecting: selection)
        if isSearchActive { scheduleSearch() }
    }

    /// Restarts the recursive search (debounced) for the current query, or clears results when it is empty.
    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isThisMac else {
            searchTask = nil
            isSearching = false
            if !searchResults.isEmpty { searchResults = [] }
            itemsVersion += 1
            return
        }
        let root = url
        let includeHidden = settings.showHiddenFiles
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            var found: [FileItem] = []
            for await batch in FileSearch.run(in: root, query: query, includeHidden: includeHidden) {
                guard let self, !Task.isCancelled else { return }
                found += batch
                self.searchResults = found
                self.itemsVersion += 1
            }
            guard let self, !Task.isCancelled else { return }
            if found.isEmpty {
                self.searchResults = []
                self.itemsVersion += 1
            }
            self.isSearching = false
        }
    }

    func requestListFocus() {
        focusListToken += 1
    }

    @ObservationIgnored private var selectAfterLoad: Set<URL> = []

    private func move(to destination: URL, selecting: Set<URL>) {
        url = destination
        let mode = FolderViewModes.mode(for: destination)
        if viewMode != mode { viewMode = mode }
        searchText = ""
        selection = []
        items = []
        itemsVersion += 1
        load(selecting: selecting)
    }

    private func load(selecting: Set<URL>) {
        selectAfterLoad = selecting
        let target = url
        if isThisMac {
            // Not a folder: ThisMacView shows the drives itself.
            loadTask?.cancel()
            watcher = nil
            watcherURL = nil
            lastLoadError = nil
            isLoading = false
            return
        }
        if watcher == nil || watcherURL != target {
            watcher = DirectoryWatcher(directory: target) { [weak self] in self?.reload() }
            watcherURL = target
        }
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                let loaded = try await DirectoryLoader.load(target)
                guard let self, !Task.isCancelled, self.url == target else { return }
                self.apply(loaded)
            } catch {
                guard let self, !Task.isCancelled, self.url == target else { return }
                self.items = []
                self.itemsVersion += 1
                self.lastLoadError = error as NSError
                self.isLoading = false
            }
        }
    }

    @ObservationIgnored private var watcherURL: URL?

    private func apply(_ loaded: [FileItem]) {
        lastLoadError = nil
        isLoading = false
        if loaded != items {
            items = loaded
            itemsVersion += 1
        }
        let present = Set(loaded.map(\.url))
        let wanted = selectAfterLoad.isEmpty ? selection : selectAfterLoad
        selection = wanted.intersection(present)
        selectAfterLoad = []
    }

    // MARK: Helpers

    /// Address-bar labels keep the filesystem's names, independent of the interface language.
    static func pathName(of url: URL) -> String {
        if url == thisMacURL { return "This Mac" }
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "/"
        }
        return url.lastPathComponent
    }

    static func displayName(of url: URL) -> String {
        if url == thisMacURL { return L10n.text("This Mac") }
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
        }
        if let standard = (StandardLocations.pinned + [StandardLocations.home]).first(where: { $0.url.normalizedFileURL == url.normalizedFileURL }) {
            return standard.title
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
            return L10n.text("Access is denied. Grant Foldera Full Disk Access in System Settings › Privacy & Security to open this folder.")
        }
        return nsError.localizedDescription
    }
}
