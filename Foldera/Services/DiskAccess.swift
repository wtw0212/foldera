import AppKit
import Observation

/// Tracks whether Foldera has Full Disk Access. With it, macOS stops asking for each protected
/// folder (Desktop, Documents, Downloads, removable drives…) one at a time.
@Observable
final class DiskAccess {
    static let shared = DiskAccess()

    private(set) var hasFullDiskAccess = DiskAccess.check()
    var isBannerDismissed: Bool {
        didSet { UserDefaults.standard.set(isBannerDismissed, forKey: "fullDiskAccessBannerDismissed") }
    }

    var showsBanner: Bool { !hasFullDiskAccess && !isBannerDismissed }

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private init() {
        isBannerDismissed = UserDefaults.standard.bool(forKey: "fullDiskAccessBannerDismissed")
        // Re-check when the user comes back from System Settings.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasFullDiskAccess = DiskAccess.check() }
        }
        if showsBanner { startPolling() }
    }

    /// macOS never lists apps under Full Disk Access by itself: the user has to add them with "+"
    /// or by dragging the app into the list. Open the pane, then show Foldera.app in Finder beside it
    /// so it can be dragged straight in.
    func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    /// Where the running app lives, for the instructions.
    var appLocation: String {
        (Bundle.main.bundleURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    /// True when running from somewhere other than an Applications folder (e.g. Xcode's build folder).
    var isRunningOutsideApplications: Bool {
        !Bundle.main.bundleURL.path.contains("/Applications/")
    }

    /// Folders that only an app with Full Disk Access can list. Reading them never shows a prompt.
    /// Several are tried because not every Mac has all of them.
    private static let probes = [
        "Library/Application Support/com.apple.TCC",
        "Library/Safari",
        "Library/Mail",
        "Library/Messages",
    ]

    static func check() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return probes.contains { path in
            let url = home.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        }
    }

    /// Re-checks every few seconds while access is missing, so the bar disappears soon after it's granted.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                // Once the bar is dismissed nothing shows the result; becoming active re-checks anyway.
                guard let self, !self.isBannerDismissed else { return }
                if DiskAccess.check() {
                    self.hasFullDiskAccess = true
                    return
                }
            }
        }
    }
}
