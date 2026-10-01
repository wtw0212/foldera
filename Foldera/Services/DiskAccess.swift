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

    private init() {
        isBannerDismissed = UserDefaults.standard.bool(forKey: "fullDiskAccessBannerDismissed")
        // Re-check when the user comes back from System Settings.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasFullDiskAccess = DiskAccess.check() }
        }
    }

    func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    /// The TCC database folder is only listable with Full Disk Access, and reading it never triggers a prompt.
    private static func check() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }
}
