import AppKit
import Observation
import SwiftUI

/// Folders pinned to Quick access in the navigation pane. Saved across launches.
@Observable
final class QuickAccess {
    static let shared = QuickAccess()

    private(set) var urls: [URL]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "quickAccessPins"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let paths = defaults.stringArray(forKey: Self.key) {
            urls = paths.map { URL(fileURLWithPath: $0).normalizedFileURL }
        } else {
            urls = StandardLocations.pinned.map(\.url.normalizedFileURL)
        }
    }

    var locations: [Location] { urls.map(Self.location(for:)) }

    func isPinned(_ url: URL) -> Bool {
        urls.contains(url.normalizedFileURL)
    }

    func pin(_ url: URL) {
        let url = url.normalizedFileURL
        guard !urls.contains(url) else { return }
        urls.append(url)
        save()
    }

    func unpin(_ url: URL) {
        urls.removeAll { $0 == url.normalizedFileURL }
        save()
    }

    /// Pins folders dropped onto Quick access, just before `target` (nil: at the end, or the start when
    /// `atStart`). Folders that are already pinned move to the drop position.
    func insert(_ folders: [URL], before target: URL?, atStart: Bool = false) {
        let folders = folders.map(\.normalizedFileURL)
        guard !folders.isEmpty, target.map({ !folders.contains($0.normalizedFileURL) }) ?? true else { return }
        urls.removeAll { folders.contains($0) }
        let index = target.flatMap { urls.firstIndex(of: $0.normalizedFileURL) } ?? (atStart ? 0 : urls.endIndex)
        var seen = Set<URL>()
        urls.insert(contentsOf: folders.filter { seen.insert($0).inserted }, at: index)
        save()
    }

    /// Dropped items that can be pinned: folders, not files or packages.
    static func pinnableFolders(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
    }

    private func save() {
        defaults.set(urls.map(\.path), forKey: Self.key)
    }

    /// Standard folders keep their colored icons; anything else shows as a folder.
    static func location(for url: URL) -> Location {
        if let standard = (StandardLocations.pinned + [StandardLocations.home]).first(where: { $0.url.normalizedFileURL == url }) {
            return standard
        }
        return Location(
            url: url,
            title: FileManager.default.displayName(atPath: url.path),
            symbol: "folder_filled",
            tint: Theme.folderFront.swiftUI
        )
    }
}

/// Expandable folder tree for the navigation pane, loaded lazily as folders are expanded.
@Observable
final class FolderTree {
    struct Row: Identifiable {
        let url: URL
        let depth: Int
        let key: String
        var id: String { key }
    }

    private var expanded: Set<String> = []
    private var children: [String: [URL]] = [:]

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

    /// nil until loaded; empty when the folder has no subfolders.
    func knownChildren(_ key: String) -> [URL]? { children[key] }

    func toggle(_ key: String, url: URL) {
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            children[key] = Self.subfolders(of: url)
            expanded.insert(key)
        }
    }

    /// The visible rows under `root`, depth-first, following expanded folders.
    func rows(under root: URL, section: String) -> [Row] {
        var result: [Row] = []
        func visit(_ url: URL, depth: Int, key: String) {
            guard expanded.contains(key) else { return }
            for child in children[key] ?? [] {
                let childKey = key + "/" + child.lastPathComponent
                result.append(Row(url: child, depth: depth, key: childKey))
                visit(child, depth: depth + 1, key: childKey)
            }
        }
        visit(root, depth: 1, key: section)
        return result
    }

    private static func subfolders(of url: URL) -> [URL] {
        let showHidden = AppSettings.shared.showHiddenFiles
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .map(\.normalizedFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
