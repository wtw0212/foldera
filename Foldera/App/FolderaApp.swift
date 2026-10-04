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

    /// Waits for current uploads, then warns when saved edits still need recovery after quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !editing.pendingFiles.isEmpty || editing.isUploading else { return .terminateNow }
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
            + L10n.text("If you quit now, these changes are kept in Server Files for recovery and won’t reach the server. Use Resume Recovered Edits after reopening Foldera.")
        alert.addButton(withTitle: L10n.text("Don’t Quit"))
        alert.addButton(withTitle: L10n.text("Quit Anyway"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        editing.prepareToQuit()
    }
}
