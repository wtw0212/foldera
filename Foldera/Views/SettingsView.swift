import SwiftUI

/// Foldera ▸ Settings… (⌘,), similar in spirit to Explorer's Folder Options.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ViewSettings()
                .tabItem { Label("View", systemImage: "eye") }
            AccessSettings()
                .tabItem { Label("Access", systemImage: "lock.shield") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Picker("Open new windows and tabs in:", selection: $settings.startLocation) {
                ForEach(StartLocation.allCases) { Text($0.title).tag($0) }
            }
            Picker("Return key:", selection: $settings.returnKeyRenames) {
                Text("Opens the item (like Windows)").tag(false)
                Text("Renames the item (like Finder)").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text("F2 always renames. ⌘↓ always opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ViewSettings: View {
    @State private var settings = AppSettings.shared
    @State private var defaultMode = FolderViewModes.defaultMode
    @State private var didReset = false

    var body: some View {
        Form {
            Picker("Layout for new folders:", selection: $defaultMode) {
                ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: defaultMode) { _, mode in FolderViewModes.defaultMode = mode }
            LabeledContent("Folder layouts:") {
                Button(didReset ? "Reset" : "Reset All Folders") {
                    FolderViewModes.resetAll()
                    didReset = true
                }
                .disabled(didReset)
            }
            Divider()
            Toggle("Show hidden items", isOn: $settings.showHiddenFiles)
            Toggle("Show file name extensions", isOn: $settings.showExtensions)
            Toggle("Compact view", isOn: $settings.compactView)
            Toggle("Show navigation pane", isOn: $settings.showNavigationPane)
        }
    }
}

private struct AccessSettings: View {
    @State private var access = DiskAccess.shared

    var body: some View {
        Form {
            LabeledContent("Full Disk Access:") {
                Label(
                    access.hasFullDiskAccess ? "Granted" : "Not granted",
                    systemImage: access.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(access.hasFullDiskAccess ? .green : .orange)
            }
            Text("With Full Disk Access, macOS stops asking for permission folder by folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !access.hasFullDiskAccess {
                Button("Open Privacy & Security Settings") { access.openSettings() }
                Toggle("Show the reminder bar in windows", isOn: Binding(
                    get: { !access.isBannerDismissed },
                    set: { access.isBannerDismissed = !$0 }
                ))
            }
        }
    }
}
