import Foundation
import Observation

/// A folder or file the user opened recently.
nonisolated struct RecentItem: Codable, Hashable, Identifiable, Sendable {
    let url: URL
    let isFolder: Bool

    var id: URL { url }
    var name: String { url.isRemote ? RemotePath.name(of: url.remotePath) : FileManager.default.displayName(atPath: url.path) }
}

/// Recently opened folders and files, newest first, for the navigation pane's Recent section.
@Observable
final class RecentItems {
    /// How many are remembered; the navigation pane shows the first few (Settings ▸ General).
    static let capacity = 50

    private(set) var items: [RecentItem]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "recentItems"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([RecentItem].self, from: $0) } ?? []
    }

    /// Moves `url` to the top. This Mac and Network are pages, not items, and aren't recorded.
    func record(_ url: URL, isFolder: Bool) {
        guard url.isFileURL || url.isRemote else { return }
        let url = url.normalizedFileURL
        items.removeAll { $0.url == url }
        items.insert(RecentItem(url: url, isFolder: isFolder), at: 0)
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        persist()
    }

    func remove(_ url: URL) {
        items.removeAll { $0.url == url.normalizedFileURL }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    /// The newest `count` items, skipping local ones that have since been deleted or moved.
    /// Server items are kept: checking them would mean connecting.
    func visible(_ count: Int) -> [RecentItem] {
        guard count > 0 else { return [] }
        var result: [RecentItem] = []
        for item in items where result.count < count {
            if item.url.isRemote || FileManager.default.fileExists(atPath: item.url.path) { result.append(item) }
        }
        return result
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.key)
    }
}
