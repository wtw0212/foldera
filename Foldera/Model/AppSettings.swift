import AppKit
import Observation

/// The optional pane on the right of the file list (View ▸ Show). The Details pane includes a live preview.
enum SidePane: String {
    case none, details
}

/// Light, dark, or follow macOS (Settings ▸ View ▸ Theme).
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.text("System")
        case .light: L10n.text("Light")
        case .dark: L10n.text("Dark")
        }
    }

    /// nil follows the system appearance.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Where new windows and tabs open.
enum StartLocation: String, CaseIterable, Identifiable {
    case home, desktop, documents, downloads

    var id: String { rawValue }
    var title: String { L10n.text(rawValue.capitalized) }

    var url: URL {
        let fm = FileManager.default
        let directory: FileManager.SearchPathDirectory? = switch self {
        case .home: nil
        case .desktop: .desktopDirectory
        case .documents: .documentDirectory
        case .downloads: .downloadsDirectory
        }
        return directory.flatMap { fm.urls(for: $0, in: .userDomainMask).first } ?? fm.homeDirectoryForCurrentUser
    }
}

/// App-wide view preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey) } }

    var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            applyTheme()
        }
    }

    /// Every window and Theme color follows the app's appearance.
    func applyTheme() {
        NSApplication.shared.appearance = theme.appearance
    }

    var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: Key.showHiddenFiles) } }
    var showExtensions: Bool { didSet { defaults.set(showExtensions, forKey: Key.showExtensions) } }
    var compactView: Bool { didSet { defaults.set(compactView, forKey: Key.compactView) } }
    var showNavigationPane: Bool { didSet { defaults.set(showNavigationPane, forKey: Key.showNavigationPane) } }
    var sidePane: SidePane { didSet { defaults.set(sidePane.rawValue, forKey: Key.sidePane) } }
    /// Return renames like Finder instead of opening like Explorer.
    var returnKeyRenames: Bool { didSet { defaults.set(returnKeyRenames, forKey: Key.returnKeyRenames) } }
    var startLocation: StartLocation { didSet { defaults.set(startLocation.rawValue, forKey: Key.startLocation) } }
    /// Bundle ID of the terminal that "cmd" in the address bar opens.
    var terminalApp: String { didSet { defaults.set(terminalApp, forKey: Key.terminalApp) } }
    /// How many recent items the navigation pane shows; 0 hides the Recent section.
    var recentItemsCount: Int { didSet { defaults.set(recentItemsCount, forKey: Key.recentItemsCount) } }
    static let recentItemsChoices = [0, 3, 5, 10, 15, 20]
    /// Recently opened folders and files, stored alongside these settings.
    @ObservationIgnored let recents: RecentItems

    /// Shows `pane`, or hides it if it is already showing (like Explorer's toggles).
    func toggle(_ pane: SidePane) {
        sidePane = sidePane == pane ? .none : pane
    }

    var rowHeight: CGFloat { compactView ? 22 : 30 }

    @ObservationIgnored let defaults: UserDefaults

    private enum Key {
        static let showHiddenFiles = "showHiddenFiles"
        static let theme = "theme"
        static let showExtensions = "showExtensions"
        static let compactView = "compactView"
        static let showNavigationPane = "showNavigationPane"
        static let sidePane = "sidePane"
        static let returnKeyRenames = "returnKeyRenames"
        static let startLocation = "startLocation"
        static let terminalApp = "terminalApp"
        static let recentItemsCount = "recentItemsCount"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage.saved(in: defaults)
        theme = defaults.string(forKey: Key.theme).flatMap { AppTheme(rawValue: $0.lowercased()) } ?? .system
        defaults.register(defaults: [
            Key.showHiddenFiles: false,
            Key.showExtensions: true,
            Key.compactView: false,
            Key.showNavigationPane: true,
            Key.recentItemsCount: 5,
        ])
        recents = RecentItems(defaults: defaults)
        recentItemsCount = max(0, defaults.integer(forKey: Key.recentItemsCount))
        showHiddenFiles = defaults.bool(forKey: Key.showHiddenFiles)
        showExtensions = defaults.bool(forKey: Key.showExtensions)
        compactView = defaults.bool(forKey: Key.compactView)
        showNavigationPane = defaults.bool(forKey: Key.showNavigationPane)
        returnKeyRenames = defaults.bool(forKey: Key.returnKeyRenames)
        startLocation = defaults.string(forKey: Key.startLocation).flatMap(StartLocation.init(rawValue:)) ?? .home
        terminalApp = defaults.string(forKey: Key.terminalApp) ?? "com.apple.Terminal"
        // "preview" was a separate pane in earlier builds; it is part of Details now.
        let storedPane = defaults.string(forKey: Key.sidePane)
        sidePane = storedPane == "preview" ? .details : storedPane.flatMap(SidePane.init(rawValue:)) ?? .none
    }
}
