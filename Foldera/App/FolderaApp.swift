import SwiftUI

@main
struct FolderaApp: App {
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
