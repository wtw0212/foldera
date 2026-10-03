import SwiftUI

@main
struct FolderaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: FolderaAppDelegate

    init() {
        AppSettings.shared.applyTheme()
    }

    var body: some Scene {
        WindowGroup {
            ExplorerWindow()
                .environment(\.locale, L10n.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 720)
        .commands {
            FolderaCommands()
        }

        Settings {
            SettingsView()
                .environment(\.locale, L10n.locale)
        }
    }
}

final class FolderaAppDelegate: NSObject, NSApplicationDelegate {
    var editing: RemoteEditing = .shared
    /// Asks whether to quit with these files still pending. Replaced in tests.
    var confirm: @MainActor ([String]) -> Bool = FolderaAppDelegate.confirmQuit
    /// Answers a `.terminateLater`. Replaced in tests.
    var reply: @MainActor (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }

    /// Server files edited in other apps whose last save hasn't reached the server yet would be lost on quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !editing.pendingFiles.isEmpty else { return .terminateNow }
        Task {
            await editing.uploadNow()
            let stillPending = editing.pendingFiles
            reply(stillPending.isEmpty || confirm(stillPending))
        }
        return .terminateLater
    }

    static func confirmQuit(_ files: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("%lld edited server files haven’t been uploaded", files.count)
        alert.informativeText = files.prefix(5).joined(separator: "\n") + "\n\n"
            + L10n.text("If you quit now, these changes stay only in Foldera’s temporary copies and won’t reach the server.")
        alert.addButton(withTitle: L10n.text("Don’t Quit"))
        alert.addButton(withTitle: L10n.text("Quit Anyway"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}
