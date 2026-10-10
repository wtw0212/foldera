import Foundation

/// Explorer's layouts (View ▸ …). Windows' Ctrl+Shift+1…8 become ⌥⌘1…8 (⇧⌘3–5 are macOS screenshot keys).
enum ViewMode: String, CaseIterable, Identifiable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details, tiles, content

    var id: String { rawValue }

    // Keep each layout's presentation in one exhaustive switch.
    private var presentation: (title: String, symbol: String, iconSize: CGFloat) {
        switch self {
        case .extraLargeIcons: ("Extra large icons", "photo", 256)
        case .largeIcons: ("Large icons", "square.grid.2x2", 96)
        case .mediumIcons: ("Medium icons", "square.grid.3x3", 48)
        case .smallIcons: ("Small icons", "square.grid.4x3.fill", 16)
        case .list: ("List", "list.bullet", 16)
        case .details: ("Details", "list.bullet.rectangle", 16)
        case .tiles: ("Tiles", "rectangle.grid.2x2", 48)
        case .content: ("Content", "rectangle.grid.1x2", 48)
        }
    }

    var title: String { L10n.text(presentation.title) }
    var symbol: String { presentation.symbol }
    /// Icon edge length in points.
    var iconSize: CGFloat { presentation.iconSize }

    /// Modes that show image thumbnails instead of file type icons.
    var showsThumbnails: Bool { iconSize >= 48 }

    var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

extension ViewMode {
    /// ⌘+ / ⌘− and ⌘-scroll or pinch step through these, smallest to largest, like Ctrl+wheel in Explorer.
    static let zoomOrder: [ViewMode] = [.details, .list, .smallIcons, .mediumIcons, .largeIcons, .extraLargeIcons]

    /// The next layout up (bigger) or down, stopping at either end. Tiles and Content count as medium icons.
    func zoomed(in zoomIn: Bool) -> ViewMode {
        let index = Self.zoomOrder.firstIndex(of: self) ?? Self.zoomOrder.firstIndex(of: .mediumIcons) ?? 0
        let next = min(max(index + (zoomIn ? 1 : -1), 0), Self.zoomOrder.count - 1)
        return Self.zoomOrder[next]
    }
}

enum FileColumn: String, CaseIterable, Codable {
    case name, location, dateModified, kind, size

    var field: SortField? { SortField(rawValue: rawValue) }
    var title: String { field?.title ?? L10n.text("Folder") }
    var width: CGFloat {
        switch self {
        case .name: 320
        case .location: 280
        case .dateModified: 160
        case .kind: 150
        case .size: 100
        }
    }
}

struct DetailColumns: Codable, Equatable {
    var order = FileColumn.allCases
    var widths: [String: Double] = [:]
    var hidden: Set<FileColumn> = []

    var ordered: [FileColumn] {
        var seen: Set<FileColumn> = []
        return (order + FileColumn.allCases).filter { seen.insert($0).inserted }
    }

    func width(of column: FileColumn) -> CGFloat {
        guard let width = widths[column.rawValue], width.isFinite else { return column.width }
        return CGFloat(min(4096, max(60, width)))
    }

    mutating func toggle(_ column: FileColumn) {
        guard column != .name else { return }
        if !hidden.insert(column).inserted { hidden.remove(column) }
    }
}

struct FolderDetails: Codable, Equatable {
    var sort = SortOrder()
    var columns = DetailColumns()
}

/// Remembers view settings per folder; new folders use the last layout chosen anywhere.
enum FolderViewModes {
    private static let key = "folderViewModes"
    private static let defaultKey = "defaultViewMode"
    private static let detailsKey = "folderDetailsView"

    static func mode(for folder: URL, defaults: UserDefaults = .standard) -> ViewMode {
        let saved = defaults.dictionary(forKey: key) as? [String: String]
        let raw = saved?[folder.absoluteString] ?? (folder.isFileURL ? saved?[folder.path] : nil) ?? defaults.string(forKey: defaultKey)
        return raw.flatMap(ViewMode.init(rawValue:)) ?? .details
    }

    /// Layout for folders that haven't been given one.
    static var defaultMode: ViewMode {
        get { UserDefaults.standard.string(forKey: defaultKey).flatMap(ViewMode.init(rawValue:)) ?? .details }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultKey) }
    }

    /// Forgets every per-folder layout.
    static func resetAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: detailsKey)
    }

    static func set(_ mode: ViewMode, for folder: URL, defaults: UserDefaults = .standard) {
        var saved = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        saved[folder.absoluteString] = mode.rawValue
        defaults.set(saved, forKey: key)
        defaults.set(mode.rawValue, forKey: defaultKey)
    }

    static func details(for folder: URL, defaults: UserDefaults = .standard) -> FolderDetails {
        guard let data = (defaults.dictionary(forKey: detailsKey) as? [String: Data])?[folder.absoluteString],
              let details = try? JSONDecoder().decode(FolderDetails.self, from: data) else { return FolderDetails() }
        return details
    }

    static func setDetails(_ details: FolderDetails, for folder: URL, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(details) else { return }
        var saved = defaults.dictionary(forKey: detailsKey) as? [String: Data] ?? [:]
        saved[folder.absoluteString] = data
        defaults.set(saved, forKey: detailsKey)
    }
}
