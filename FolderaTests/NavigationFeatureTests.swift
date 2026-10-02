import AppKit
import Testing
@testable import Foldera

@MainActor
struct NavigationFeatureTests {
    @Test func swipeReleaseKeepsFeedbackAndNavigationInSync() {
        let releases: [(CGFloat, NSEvent.Phase, Bool)] = [
            (0.1, .ended, false),
            (SwipeFeedback.threshold - 0.001, .ended, false),
            (SwipeFeedback.threshold, .ended, true),
            (0.8, .ended, true),
            (0.8, .cancelled, false)
        ]
        for direction in [SwipeFeedback.Direction.back, .forward] {
            let sign: CGFloat = direction == .back ? 1 : -1
            for (amount, phase, shouldNavigate) in releases {
                let feedback = SwipeFeedback()
                var backCount = 0
                var forwardCount = 0
                let handlers = NavigationGestures(
                    feedback: feedback,
                    back: { backCount += 1 },
                    forward: { forwardCount += 1 },
                    canGoBack: { true },
                    canGoForward: { true }
                )
                #expect(!handlers.updateSwipe(direction, amount: 0, phase: .began, isComplete: false))
                // Crossing the threshold then reversing must use the distance at release.
                #expect(!handlers.updateSwipe(direction, amount: sign * 0.8, phase: .changed, isComplete: false))
                #expect(!handlers.updateSwipe(direction, amount: sign * amount, phase: .changed, isComplete: false))
                #expect(feedback.isArmed == (amount >= SwipeFeedback.threshold))
                #expect(handlers.updateSwipe(direction, amount: sign * amount, phase: phase, isComplete: false))
                #expect(!feedback.isActive)
                #expect(backCount == (shouldNavigate && direction == .back ? 1 : 0))
                #expect(forwardCount == (shouldNavigate && direction == .forward ? 1 : 0))
                // A late settling frame must not revive a cancelled arrow or navigate again.
                #expect(!handlers.updateSwipe(direction, amount: sign, phase: [], isComplete: false))
                #expect(!feedback.isActive)
                #expect(!feedback.isArmed)
                #expect(handlers.updateSwipe(direction, amount: sign, phase: [], isComplete: true))
                #expect(backCount + forwardCount == (shouldNavigate ? 1 : 0))
            }
        }
    }

    @Test func backgroundTabsOpenInOrderAfterTheActiveTab() {
        let model = ExplorerWindowModel(url: URL(fileURLWithPath: "/"))
        let first = model.activeTabID
        model.newTab(url: URL(fileURLWithPath: "/tmp"))
        let active = model.activeTabID
        model.activeTabID = first
        model.newTab(url: URL(fileURLWithPath: "/usr"), activate: false)
        model.newTab(url: URL(fileURLWithPath: "/var"), activate: false)
        #expect(model.activeTabID == first)
        #expect(model.tabs.map(\.url.path) == ["/", "/usr", "/var", "/tmp"])
        // Switching tabs starts a fresh run of background tabs.
        model.activeTabID = active
        model.newTab(url: URL(fileURLWithPath: "/bin"), activate: false)
        #expect(model.tabs.map(\.url.path).last == "/bin")
    }

    @Test func cloudStorageFolderTitles() {
        let base = URL(fileURLWithPath: "/nonexistent/CloudStorage")
        #expect(CloudDrives.title(forStorageFolder: base.appendingPathComponent("OneDrive-Personal")) == "OneDrive - Personal")
        #expect(CloudDrives.title(forStorageFolder: base.appendingPathComponent("GoogleDrive-me@example.com")) == "Google Drive - me@example.com")
        #expect(CloudDrives.title(forStorageFolder: base.appendingPathComponent("Box-Box")) == "Box")
        #expect(CloudDrives.title(forStorageFolder: base.appendingPathComponent("Dropbox")) == "Dropbox")
    }

    @Test func addressCommandParsing() {
        #expect(AddressCommand.split("  code  src/app ") == ("code", "src/app"))
        #expect(AddressCommand.split("terminal") == ("terminal", ""))
        #expect(AddressCommand.shellQuoted("/Users/me/it's here") == "'/Users/me/it'\\''s here'")
        #expect(AddressCommand.executableOnPath("ls"))
        #expect(!AddressCommand.executableOnPath("definitely-not-a-command-xyz"))
        #expect(!AddressCommand.executableOnPath("../ls"))
        #expect(AddressCommand.application(named: "safari")?.lastPathComponent == "Safari.app")
    }
}
