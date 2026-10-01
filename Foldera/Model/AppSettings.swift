import Foundation
import Observation

/// App-wide view preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: Key.showHiddenFiles) } }
    var showExtensions: Bool { didSet { defaults.set(showExtensions, forKey: Key.showExtensions) } }
    var compactView: Bool { didSet { defaults.set(compactView, forKey: Key.compactView) } }
    var showNavigationPane: Bool { didSet { defaults.set(showNavigationPane, forKey: Key.showNavigationPane) } }

    var rowHeight: CGFloat { compactView ? 22 : 30 }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let showHiddenFiles = "showHiddenFiles"
        static let showExtensions = "showExtensions"
        static let compactView = "compactView"
        static let showNavigationPane = "showNavigationPane"
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
    }
}
