import SwiftUI

/// Foldera ▸ Settings… (⌘,), similar in spirit to Explorer's Folder Options.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L10n.text("General"), systemImage: "gearshape") }
            ViewSettings()
                .tabItem { Label(L10n.text("View"), systemImage: "eye") }
            CloudSettings()
                .tabItem { Label(L10n.text("Cloud"), systemImage: "cloud") }
            AccessSettings()
                .tabItem { Label(L10n.text("Access"), systemImage: "lock.shield") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @State private var settings = AppSettings.shared

    init(settings: AppSettings = .shared) { _settings = State(initialValue: settings) }

    var body: some View {
        Form {
            Picker(L10n.text("Language:"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text("Open new windows and tabs in:"), selection: $settings.startLocation) {
                ForEach(StartLocation.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text("Return key:"), selection: $settings.returnKeyRenames) {
                Text(L10n.text("Opens the item (like Windows)")).tag(false)
                Text(L10n.text("Renames the item (like Finder)")).tag(true)
            }
            .pickerStyle(.radioGroup)
            Text(L10n.text("F2 always renames. ⌘↓ always opens."))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            Picker(L10n.text("Terminal:"), selection: $settings.terminalApp) {
                ForEach(installedTerminals, id: \.id) { Text($0.name).tag($0.id) }
            }
            Text(L10n.text("Type “terminal” in the address bar to open it in the current folder, or a command (“git status”) to run it there."))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
    }

    private var installedTerminals: [(id: String, name: String)] {
        AddressCommand.terminals.filter { $0.id == settings.terminalApp || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }
}

struct CloudSettings: View {
    @State private var cloud = CloudDrives.shared

    init(cloud: CloudDrives = .shared) { _cloud = State(initialValue: cloud) }

    var body: some View {
        Form {
            LabeledContent(L10n.text("Cloud drives:")) {
                VStack(alignment: .leading, spacing: 6) {
                    if cloud.locations.isEmpty {
                        Text(L10n.text("None found")).foregroundStyle(.secondary)
                    }
                    ForEach(cloud.locations) { location in
                        HStack {
                            Label(location.title, systemImage: "cloud.fill")
                                .foregroundStyle(location.tint)
                            Spacer()
                            if cloud.isAdded(location.url) {
                                Button(L10n.text("Remove")) { cloud.remove(location.url) }
                            }
                        }
                        .help(location.url.path)
                    }
                    Button(L10n.text("Add Folder…")) { cloud.chooseFolder() }
                }
            }
            Text(L10n.text("OneDrive, Google Drive, Dropbox and Box show up here by themselves once their app is set up. Add Folder shows any other synced or network folder in the navigation pane."))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if !cloud.missingProviders.isEmpty {
                LabeledContent(L10n.text("Get a cloud app:")) {
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

struct ViewSettings: View {
    @State private var settings = AppSettings.shared
    @State private var defaultMode = FolderViewModes.defaultMode
    @State private var didReset = false

    init(settings: AppSettings = .shared) { _settings = State(initialValue: settings) }

    var body: some View {
        Form {
            Picker(L10n.text("Theme:"), selection: $settings.theme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker(L10n.text("Layout for new folders:"), selection: $defaultMode) {
                ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: defaultMode) { _, mode in FolderViewModes.defaultMode = mode }
            LabeledContent(L10n.text("Folder layouts:")) {
                Button(didReset ? L10n.text("Reset") : L10n.text("Reset All Folders")) {
                    FolderViewModes.resetAll()
                    didReset = true
                }
                .disabled(didReset)
            }
            Divider()
            Toggle(L10n.text("Show hidden items"), isOn: $settings.showHiddenFiles)
            Toggle(L10n.text("Show file name extensions"), isOn: $settings.showExtensions)
            Toggle(L10n.text("Compact view"), isOn: $settings.compactView)
            Toggle(L10n.text("Show navigation pane"), isOn: $settings.showNavigationPane)
        }
    }
}

struct AccessSettings: View {
    @State private var access = DiskAccess.shared

    var body: some View {
        Form {
            LabeledContent(L10n.text("Full Disk Access:")) {
                Label(
                    access.hasFullDiskAccess ? L10n.text("Granted") : L10n.text("Not granted"),
                    systemImage: access.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(access.hasFullDiskAccess ? .green : .orange)
            }
            Text(L10n.text("With Full Disk Access, macOS stops asking for permission folder by folder."))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if !access.hasFullDiskAccess {
                Button(L10n.text("Open Privacy & Security Settings")) { access.openSettings() }
                Text(L10n.text("macOS doesn't add apps to this list by itself. Drag Foldera (revealed in Finder) into the list, or click + and choose it, then turn it on. If it still says Not granted, quit and reopen Foldera — macOS applies the change on relaunch."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                if access.isRunningOutsideApplications {
                    Text(L10n.format("Foldera is running from %@. Install it in Applications first (from the DMG) so the permission sticks to the copy you use.", access.appLocation))
                        .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.orange)
                }
                Toggle(L10n.text("Show the reminder bar in windows"), isOn: Binding(
                    get: { !access.isBannerDismissed },
                    set: { access.isBannerDismissed = !$0 }
                ))
            }
        }
    }
}
