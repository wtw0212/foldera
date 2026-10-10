import Foundation
import Observation
import Sparkle

/// Installs new GitHub releases with Sparkle. Info.plist names the feed (the latest release's appcast.xml) and the
/// public key every update must be signed with; an update that fails the check is never installed.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Debug and test builds never contact the feed.
    static var startsAutomatically: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false

    var automaticallyChecks: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    /// Downloads in the background and installs when Foldera quits.
    var automaticallyInstalls: Bool {
        didSet { updater.automaticallyDownloadsUpdates = automaticallyInstalls }
    }

    private var updater: SPUUpdater { controller.updater }

    init(starting: Bool = AppUpdater.startsAutomatically) {
        controller = SPUStandardUpdaterController(startingUpdater: starting, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyInstalls = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
