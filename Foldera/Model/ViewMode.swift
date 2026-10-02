import Foundation

/// Explorer's layouts (View ▸ …). Windows' Ctrl+Shift+1…8 become ⌥⌘1…8 (⇧⌘3–5 are macOS screenshot keys).
enum ViewMode: String, CaseIterable, Identifiable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details, tiles, content

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extraLargeIcons: L10n.text("Extra large icons")
        case .largeIcons: L10n.text("Large icons")
        case .mediumIcons: L10n.text("Medium icons")
        case .smallIcons: L10n.text("Small icons")
        case .list: L10n.text("List")
        case .details: L10n.text("Details")
        case .tiles: L10n.text("Tiles")
        case .content: L10n.text("Content")
        }
    }

    var symbol: String {
        switch self {
        case .extraLargeIcons: "photo"
        case .largeIcons: "square.grid.2x2"
        case .mediumIcons: "square.grid.3x3"
        case .smallIcons: "square.grid.4x3.fill"
        case .list: "list.bullet"
        case .details: "list.bullet.rectangle"
        case .tiles: "rectangle.grid.2x2"
        case .content: "rectangle.grid.1x2"
        }
    }

    /// Icon edge length in points.
    var iconSize: CGFloat {
        switch self {
        case .extraLargeIcons: 256
        case .largeIcons: 96
        case .mediumIcons: 48
        case .tiles, .content: 48
        case .smallIcons, .list, .details: 16
        }
    }

    /// Modes that show image thumbnails instead of file type icons.
    var showsThumbnails: Bool { iconSize >= 48 }

    var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// Remembers the layout per folder, falling back to the last layout chosen anywhere.
enum FolderViewModes {
    private static let key = "folderViewModes"
    private static let defaultKey = "defaultViewMode"

    static func mode(for folder: URL) -> ViewMode {
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        let raw = saved?[folder.path] ?? UserDefaults.standard.string(forKey: defaultKey)
        return raw.flatMap(ViewMode.init(rawValue:)) ?? .details
    }

    /// Layout for folders that haven't been given one.
    static var defaultMode: ViewMode {
        get { UserDefaults.standard.string(forKey: defaultKey).flatMap(ViewMode.init(rawValue:)) ?? .details }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultKey) }
    }

    /// Forgets every per-folder layout.
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func set(_ mode: ViewMode, for folder: URL) {
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        saved[folder.path] = mode.rawValue
        UserDefaults.standard.set(saved, forKey: key)
        UserDefaults.standard.set(mode.rawValue, forKey: defaultKey)
    }
}
