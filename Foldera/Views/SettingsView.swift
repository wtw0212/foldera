import SwiftUI

/// Foldera ▸ Settings… (⌘,), similar in spirit to Explorer's Folder Options.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ViewSettings()
                .tabItem { Label("View", systemImage: "eye") }
            CloudSettings()
                .tabItem { Label("Cloud", systemImage: "cloud") }
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
            Picker("Terminal:", selection: $settings.terminalApp) {
                ForEach(installedTerminals, id: \.id) { Text($0.name).tag($0.id) }
            }
            Text("Type “cmd” or “terminal” in the address bar to open it in the current folder, or a command (“git status”) to run it there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var installedTerminals: [(id: String, name: String)] {
        AddressCommand.terminals.filter { $0.id == settings.terminalApp || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }
}

private struct CloudSettings: View {
    @State private var cloud = CloudDrives.shared

    var body: some View {
        Form {
            LabeledContent("Cloud drives:") {
                VStack(alignment: .leading, spacing: 6) {
                    if cloud.locations.isEmpty {
                        Text("None found").foregroundStyle(.secondary)
                    }
                    ForEach(cloud.locations) { location in
                        HStack {
                            Label(location.title, systemImage: "cloud.fill")
                                .foregroundStyle(location.tint)
                            Spacer()
                            if cloud.isAdded(location.url) {
                                Button("Remove") { cloud.remove(location.url) }
                            }
                        }
                        .help(location.url.path)
                    }
                    Button("Add Folder…") { cloud.chooseFolder() }
                }
            }
            Text("OneDrive, Google Drive, Dropbox and Box show up here by themselves once their app is set up. Add Folder shows any other synced or network folder in the navigation pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !cloud.missingProviders.isEmpty {
                LabeledContent("Get a cloud app:") {
                    HStack {
                        ForEach(cloud.missingProviders) { provider in
                            Button(provider.name) { NSWorkspace.shared.open(provider.download) }
                        }
                    }
                }
            }
        }
        .onAppear { cloud.refresh() }
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
                Text("macOS doesn't add apps to this list by itself. Drag Foldera (revealed in Finder) into the list, or click + and choose it, then turn it on. If it still says Not granted, quit and reopen Foldera — macOS applies the change on relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if access.isRunningOutsideApplications {
                    Text("Foldera is running from \(access.appLocation). Install it in Applications first (from the DMG) so the permission sticks to the copy you use.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Show the reminder bar in windows", isOn: Binding(
                    get: { !access.isBannerDismissed },
                    set: { access.isBannerDismissed = !$0 }
                ))
            }
        }
    }
}
