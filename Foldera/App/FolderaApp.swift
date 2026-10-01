import SwiftUI

@main
struct FolderaApp: App {
    var body: some Scene {
        WindowGroup {
            ExplorerWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 720)
        .commands {
            FolderaCommands()
        }
    }
}
