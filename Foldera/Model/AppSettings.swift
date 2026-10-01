import Foundation
import Observation

/// The optional pane on the right of the file list (View ▸ Show). The Details pane includes a live preview.
enum SidePane: String {
    case none, details
}

/// App-wide view preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: Key.showHiddenFiles) } }
    var showExtensions: Bool { didSet { defaults.set(showExtensions, forKey: Key.showExtensions) } }
    var compactView: Bool { didSet { defaults.set(compactView, forKey: Key.compactView) } }
    var showNavigationPane: Bool { didSet { defaults.set(showNavigationPane, forKey: Key.showNavigationPane) } }
    var sidePane: SidePane { didSet { defaults.set(sidePane.rawValue, forKey: Key.sidePane) } }

    /// Shows `pane`, or hides it if it is already showing (like Explorer's toggles).
    func toggle(_ pane: SidePane) {
        sidePane = sidePane == pane ? .none : pane
    }

    var rowHeight: CGFloat { compactView ? 22 : 30 }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let showHiddenFiles = "showHiddenFiles"
        static let showExtensions = "showExtensions"
        static let compactView = "compactView"
        static let showNavigationPane = "showNavigationPane"
        static let sidePane = "sidePane"
    }

    private init() {
        defaults.register(defaults: [
            Key.showHiddenFiles: false,
            Key.showExtensions: true,
            Key.compactView: false,
            Key.showNavigationPane: true,
        ])
        showHiddenFiles = defaults.bool(forKey: Key.showHiddenFiles)
        showExtensions = defaults.bool(forKey: Key.showExtensions)
        compactView = defaults.bool(forKey: Key.compactView)
        showNavigationPane = defaults.bool(forKey: Key.showNavigationPane)
        // "preview" was a separate pane in earlier builds; it is part of Details now.
        let storedPane = defaults.string(forKey: Key.sidePane)
        sidePane = storedPane == "preview" ? .details : storedPane.flatMap(SidePane.init(rawValue:)) ?? .none
    }
}
