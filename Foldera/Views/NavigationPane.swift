import SwiftUI
import UniformTypeIdentifiers

/// Left navigation pane: Home, cloud drives, Quick access pins and "This Mac", each expandable into a folder tree.
struct NavigationPane: View {
    let model: ExplorerWindowModel
    let tab: BrowserTab
    @State private var volumes = VolumeMonitor.shared
    @State private var quickAccess = QuickAccess.shared
    @State private var cloud = CloudDrives.shared
    var sites: SFTPSites = .shared
    var connections: RemoteConnections = .shared
    var settings: AppSettings = .shared
    @State private var isRecentExpanded = true
    @State private var tree = FolderTree()
    @State private var isThisMacExpanded = true
    @State private var isNetworkExpanded = true
    /// Where a drag over Quick access would land: a pin's key or a divider, and the zone within it.
    @State private var pinDrop: (id: String, zone: PinDropZone)?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                section(StandardLocations.home, key: "home")
                if let iCloud = StandardLocations.iCloudDrive {
                    section(iCloud, key: "icloud", cloud: true)
                }
                ForEach(cloud.locations) { location in
                    section(location, key: "cloud:" + location.url.path, cloud: true)
                }
                recentSection
                pinDivider(id: "qa-start") { quickAccess.insert($0, before: nil, atStart: true) }
                let pins = quickAccess.locations
                ForEach(Array(pins.enumerated()), id: \.element.id) { index, location in
                    section(location, key: "pin:" + location.url.path, pinned: true, nextPin: index + 1 < pins.count ? pins[index + 1].url : nil)
                }
                pinDivider(id: "qa-end") { quickAccess.insert($0, before: nil) }
                NavigationRow(
                    title: L10n.text("This Mac"),
                    icon: AnyView(symbol("laptop_filled", tint: Theme.accent.swiftUI)),
                    isSelected: tab.isThisMac,
                    expansion: $isThisMacExpanded,
                    action: { open(BrowserTab.thisMacURL) }
                )
                .onMiddleClick { model.newTab(url: BrowserTab.thisMacURL, activate: false) }
                if isThisMacExpanded {
                    ForEach(volumes.localVolumes) { volume in
                        section(volume, key: "vol:" + volume.url.path, indent: 1, ejectable: volume.url.path != "/")
                    }
                }
                networkSection
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.automatic)
        .background(Theme.content.swiftUI)
    }

    /// Recently opened folders and files (Settings ▸ General sets how many).
    @ViewBuilder
    private var recentSection: some View {
        let recent = settings.recents.visible(settings.recentItemsCount)
        if settings.recentItemsCount > 0 {
            // The row opens the Recent page with everything; the chevron shows the newest few here.
            NavigationRow(
                title: L10n.text("Recent"),
                icon: AnyView(Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(Theme.accent.swiftUI).frame(width: 18, height: 18)),
                isSelected: tab.isRecent,
                expansion: recent.isEmpty ? nil : $isRecentExpanded,
                action: { open(BrowserTab.recentURL) }
            )
            .accessibilityIdentifier("nav-recent")
            .onMiddleClick { model.newTab(url: BrowserTab.recentURL, activate: false) }
            .contextMenu {
                Button(L10n.text("Open")) { open(BrowserTab.recentURL) }
                Button(L10n.text("Open in new tab")) { model.newTab(url: BrowserTab.recentURL) }
                Divider()
                Button(L10n.text("Clear Recent Items")) { settings.recents.clear() }
            }
            if isRecentExpanded {
                ForEach(recent) { item in
                    NavigationRow(
                        title: item.name,
                        icon: AnyView(Image(nsImage: Self.icon(for: item)).resizable().frame(width: 16, height: 16).frame(width: 18)),
                        isSelected: item.isFolder && tab.url == item.url,
                        indent: 1,
                        action: { tab.openRecent(item) }
                    )
                    .help(item.url.isRemote ? BrowserTab.editableAddress(of: item.url) : item.url.path)
                    .onMiddleClick { if item.isFolder { model.newTab(url: item.url, activate: false) } }
                    .contextMenu { recentMenu(item) }
                }
            }
        }
    }

    @ViewBuilder
    private func recentMenu(_ item: RecentItem) -> some View {
        Button(L10n.text("Open")) { tab.openRecent(item) }
        if item.isFolder {
            Button(L10n.text("Open in new tab")) { model.newTab(url: item.url) }
        }
        if item.url.isFileURL {
            Button(L10n.text("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        Divider()
        Button(L10n.text("Remove from Recent")) { settings.recents.remove(item.url) }
        Button(L10n.text("Clear Recent Items")) { settings.recents.clear() }
    }

    static func icon(for item: RecentItem) -> NSImage {
        if item.isFolder { return item.url.isRemote ? FileIcons.folder : FileIcons.icon(forPath: item.url) }
        if item.url.isRemote {
            let entry = RemoteEntry(path: item.url.remotePath, isDirectory: false, isSymlink: false, size: nil, modified: nil, permissions: nil)
            return FileIcons.icon(for: FileItem(remote: entry, endpoint: item.url.remoteEndpoint ?? RemoteEndpoint(host: "", username: "")))
        }
        return FileIcons.icon(for: FileItem(url: item.url))
    }

    /// Network: SFTP sites and mounted file-server shares.
    @ViewBuilder
    private var networkSection: some View {
        NavigationRow(
            title: L10n.text("Network"),
            icon: AnyView(Image(nsImage: FileIcons.network).resizable().frame(width: 18, height: 18)),
            isSelected: tab.isNetwork,
            expansion: $isNetworkExpanded,
            action: { open(BrowserTab.networkURL) }
        )
        .accessibilityIdentifier("nav-network")
        .onMiddleClick { model.newTab(url: BrowserTab.networkURL, activate: false) }
        .contextMenu {
            Button(L10n.text("Connect to Server…")) { model.networkSheet = .connect("") }
            Button(L10n.text("New SFTP Site…")) { model.networkSheet = .site(SFTPSite(), connect: true) }
        }
        if isNetworkExpanded {
            ForEach(sites.sites) { site in
                NavigationRow(
                    title: site.title,
                    icon: AnyView(Image(nsImage: FileIcons.network).resizable().frame(width: 16, height: 16).frame(width: 18)),
                    isSelected: tab.url.remoteEndpoint == site.endpoint,
                    indent: 1,
                    trailingSymbol: connections.connected.contains(site.endpoint) ? "link_regular" : nil,
                    action: { model.openSite(site, in: tab) }
                )
                .help(site.endpoint.displayName)
                .onMiddleClick { model.openSiteInNewTab(site, activate: false) }
                .contextMenu {
                    Button(L10n.text("Open")) { model.openSite(site, in: tab) }
                    Button(L10n.text("Open in new tab")) { model.openSiteInNewTab(site) }
                    Divider()
                    Button(L10n.text("Edit…")) { model.networkSheet = .site(site, connect: false) }
                    if connections.connected.contains(site.endpoint) {
                        Button(L10n.text("Disconnect")) { Task { await connections.disconnect(site.endpoint) } }
                    }
                }
            }
            ForEach(volumes.networkVolumes) { volume in
                section(volume, key: "vol:" + volume.url.path, indent: 1, ejectable: true)
            }
        }
    }

    /// The dividers around the pins also take dropped folders, pinning them first or last.
    private func pinDivider(id: String, pin: @escaping ([URL]) -> Void) -> some View {
        let targeted = pinDrop?.id == id
        return Rectangle()
            .fill(targeted ? Theme.accent.swiftUI : Theme.divider.swiftUI)
            .frame(height: targeted ? 2 : 1)
            .padding(.vertical, targeted ? 5.5 : 6)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], delegate: PinDropDelegate(
                zoneAt: { _, canPin in canPin ? .pinAfter : nil },
                perform: { _, urls in
                    let folders = QuickAccess.pinnableFolders(urls)
                    pin(folders)
                    return !folders.isEmpty
                },
                zone: pinDropBinding(id)
            ))
    }

    private func pinDropBinding(_ id: String) -> Binding<PinDropZone?> {
        Binding(
            get: { pinDrop?.id == id ? pinDrop?.zone : nil },
            set: { zone in
                if let zone { pinDrop = (id, zone) } else if pinDrop?.id == id { pinDrop = nil }
            }
        )
    }

    /// A top-level entry plus its expanded subfolders.
    @ViewBuilder
    private func section(
        _ location: Location, key: String, pinned: Bool = false, nextPin: URL? = nil,
        cloud: Bool = false, indent: Int = 0, ejectable: Bool = false
    ) -> some View {
        let row = NavigationRow(
            title: location.title,
            icon: AnyView(symbol(location.symbol, tint: location.tint)),
            isSelected: tab.url == location.url.normalizedFileURL,
            indent: indent,
            expansion: expansion(key: key, url: location.url),
            trailingSymbol: pinned ? "pin_regular" : nil,
            action: { open(location.url) }
        )
        .help(location.url.path)
        .onMiddleClick { model.newTab(url: location.url, activate: false) }
        .contextMenu { folderMenu(location.url, ejectable: ejectable ? location : nil, cloud: cloud) }

        if pinned {
            pinRow(row, folder: location.url, key: key, nextPin: nextPin)
        } else {
            row.folderDropTarget(location.url)
        }

        ForEach(tree.rows(under: location.url, section: key)) { row in
            NavigationRow(
                title: FileManager.default.displayName(atPath: row.url.path),
                icon: AnyView(
                    Image(nsImage: FileIcons.folder).resizable().frame(width: 16, height: 16).frame(width: 18)
                        .opacity(Self.isHidden(row.url) ? 0.45 : 1)
                ),
                isSelected: tab.url == row.url,
                indent: indent + row.depth,
                dimmed: Self.isHidden(row.url),
                expansion: expansion(key: row.key, url: row.url),
                action: { open(row.url) }
            )
            .help(row.url.path)
            .folderDropTarget(row.url)
            .onMiddleClick { model.newTab(url: row.url, activate: false) }
            .contextMenu { folderMenu(row.url) }
        }
    }

    /// A pin: dropping on its top or bottom edge pins folders there; the middle drops into the folder.
    private func pinRow(_ row: some View, folder: URL, key: String, nextPin: URL?) -> some View {
        let zone = pinDrop?.id == key ? pinDrop?.zone : nil
        return row
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.accent.swiftUI, lineWidth: zone == .into ? 1.5 : 0)
                    .background(RoundedRectangle(cornerRadius: 4).fill(zone == .into ? Theme.hover.swiftUI : .clear))
            )
            .overlay(alignment: zone == .pinBefore ? .top : .bottom) {
                if zone == .pinBefore || zone == .pinAfter {
                    Capsule().fill(Theme.accent.swiftUI).frame(height: 2).offset(y: zone == .pinBefore ? -1 : 1)
                }
            }
            .onDrop(of: [.fileURL], delegate: PinDropDelegate(
                zoneAt: { point, canPin in
                    guard canPin else { return .into }
                    return point.y < 9 ? .pinBefore : point.y > 21 ? .pinAfter : .into
                },
                perform: { zone, urls in
                    switch zone {
                    case .into:
                        return FileDrop.perform(urls, into: folder)
                    case .pinBefore, .pinAfter:
                        let folders = QuickAccess.pinnableFolders(urls)
                        quickAccess.insert(folders, before: zone == .pinBefore ? folder : nextPin)
                        return !folders.isEmpty
                    }
                },
                into: folder,
                zone: pinDropBinding(key)
            ))
    }

    /// Chevron state for a folder; hidden once it's known to have no subfolders.
    private func expansion(key: String, url: URL) -> Binding<Bool>? {
        if let children = tree.knownChildren(key), children.isEmpty, !tree.isExpanded(key) { return nil }
        return Binding(
            get: { tree.isExpanded(key) },
            set: { _ in tree.toggle(key, url: url) }
        )
    }

    private func open(_ url: URL) {
        tab.navigate(to: url)
        tab.requestListFocus()
    }

    @ViewBuilder
    private func folderMenu(_ url: URL, ejectable volume: Location? = nil, cloud isCloud: Bool = false) -> some View {
        Button(L10n.text("Open")) { open(url) }
        Button(L10n.text("Open in new tab")) { model.newTab(url: url) }
        Divider()
        if quickAccess.isPinned(url) {
            Button(L10n.text("Unpin from Quick access")) { quickAccess.unpin(url) }
        } else {
            Button(L10n.text("Pin to Quick access")) { quickAccess.pin(url) }
        }
        Button(L10n.text("Show in Finder")) { NSWorkspace.shared.open(url) }
        if let volume {
            Divider()
            Button(L10n.text(volumes.isEjecting(volume) ? "Ejecting…" : "Eject")) { volumes.eject(volume) }
                .disabled(volumes.isEjecting(volume))
        }
        if isCloud {
            Divider()
            if cloud.isAdded(url) {
                Button(L10n.text("Remove from navigation pane")) { cloud.remove(url) }
            }
            AddCloudDriveMenu()
        }
    }

    private static func isHidden(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? url.lastPathComponent.hasPrefix(".")
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        AppIcon(name: name, size: 18)
            .foregroundStyle(tint)
    }
}

/// "Add cloud drive" menu: any folder, or the download page of a provider that isn't set up yet.
struct AddCloudDriveMenu: View {
    @State private var cloud = CloudDrives.shared

    var body: some View {
        Menu(L10n.text("Add cloud drive")) {
            Button(L10n.text("Choose Folder…")) { cloud.chooseFolder() }
            if !cloud.missingProviders.isEmpty {
                Divider()
                ForEach(cloud.missingProviders) { provider in
                    Button(L10n.format("Get %@…", provider.name)) { NSWorkspace.shared.open(provider.download) }
                }
            }
        }
    }
}

enum PinDropZone: Equatable { case pinBefore, into, pinAfter }

/// Drags over Quick access. The dragged files come from the drag pasteboard, which is readable
/// synchronously (unlike `DropInfo` item providers), so the zone can depend on what's dragged.
private struct PinDropDelegate: DropDelegate {
    /// The zone at a point in the target, given whether any dragged item is a folder that can be pinned.
    let zoneAt: (CGPoint, _ canPin: Bool) -> PinDropZone?
    let perform: (PinDropZone, [URL]) -> Bool
    /// The folder the "into" zone drops into, for the copy/move cursor.
    var into: URL? = nil
    @Binding var zone: PinDropZone?

    private var urls: [URL] { FileDrop.fileURLs(from: NSPasteboard(name: .drag)) }

    func validateDrop(info: DropInfo) -> Bool { !urls.isEmpty }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let urls = urls
        let next = zoneAt(info.location, !QuickAccess.pinnableFolders(urls).isEmpty)
        if zone != next { zone = next }
        switch next {
        case .pinBefore, .pinAfter:
            return DropProposal(operation: .copy)
        case .into:
            guard let into else { return DropProposal(operation: .forbidden) }
            switch FileDrop.operation(for: urls, into: into) {
            case .copy: return DropProposal(operation: .copy)
            case .move: return DropProposal(operation: .move)
            case nil: return DropProposal(operation: .forbidden)
            }
        case nil:
            return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { zone = nil }
        guard let zone else { return false }
        return perform(zone, urls)
    }
}

private struct NavigationRow: View {
    let title: String
    let icon: AnyView
    let isSelected: Bool
    var indent = 0
    var dimmed = false
    var expansion: Binding<Bool>? = nil
    var trailingSymbol: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let expansion {
                    AppIcon(name: expansion.wrappedValue ? "chevron_down_regular" : "chevron_right_regular", size: 12)
                        .foregroundStyle(Theme.secondaryText.swiftUI)
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                        .onTapGesture { expansion.wrappedValue.toggle() }
                } else {
                    // Without this the empty slot (and its indent) collapses and the row sits flush left.
                    Color.clear
                }
            }
            .frame(width: 12, height: 20)
            .padding(.leading, CGFloat(indent) * 16)

            icon
            Text(title)
                .font(Theme.font)
                .foregroundStyle(dimmed ? Theme.tertiaryText.swiftUI : Theme.text.swiftUI)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailingSymbol {
                AppIcon(name: trailingSymbol, size: 13)
                    .foregroundStyle(Theme.tertiaryText.swiftUI)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Theme.selection.swiftUI : isHovered ? Theme.subtleHover.swiftUI : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
    }
}
