import SwiftUI

/// The "Network" page: SFTP sites, mounted network drives and file servers found on the local network.
struct NetworkView: View {
    let model: ExplorerWindowModel
    let tab: BrowserTab
    var onFocus: () -> Void = {}
    var sites: SFTPSites = .shared
    var connections: RemoteConnections = .shared
    var browser: NetworkBrowser = .shared
    var volumes: VolumeMonitor = .shared

    @State private var usage: [URL: DriveUsage] = [:]
    @State private var selected: String?
    @FocusState private var isFocused: Bool

    private var networkDrives: [Location] { volumes.volumes.filter { usage[$0.url]?.isNetwork == true } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Button {
                        model.networkSheet = .connect("")
                    } label: {
                        Label(L10n.text("Connect to Server…"), systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("connect-to-server")
                    Button {
                        model.networkSheet = .site(SFTPSite(), connect: true)
                    } label: {
                        Label(L10n.text("New SFTP Site…"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("new-sftp-site")
                }
                .font(Theme.font)

                section(L10n.text("SFTP sites"), count: sites.sites.count) {
                    if sites.sites.isEmpty {
                        placeholder(L10n.text("Add a site to browse a server over SFTP."))
                    } else {
                        grid {
                            ForEach(sites.sites) { site in
                                tile(id: "site:\(site.id)", icon: FileIcons.network, title: site.title,
                                     detail: connections.connected.contains(site.endpoint)
                                        ? L10n.format("%@ · Connected", site.endpoint.displayName) : site.endpoint.displayName,
                                     open: { model.openSite(site, in: tab) })
                                    .onMiddleClick { model.openSiteInNewTab(site, activate: false) }
                                    .contextMenu { siteMenu(site) }
                            }
                        }
                    }
                }

                section(L10n.text("Network drives"), count: networkDrives.count) {
                    if networkDrives.isEmpty {
                        placeholder(L10n.text("Connect to an SMB, AFP, NFS or WebDAV server to see its shares here."))
                    } else {
                        grid {
                            ForEach(networkDrives) { drive in
                                DriveTile(drive: drive, usage: usage[drive.url], isSelected: selected == drive.url.path)
                                    .onTapGesture(count: 2) { tab.navigate(to: drive.url) }
                                    .simultaneousGesture(TapGesture().onEnded { selected = drive.url.path; isFocused = true })
                                    .onMiddleClick { model.newTab(url: drive.url, activate: false) }
                                    .contextMenu {
                                        Button(L10n.text("Open")) { tab.navigate(to: drive.url) }
                                        Button(L10n.text("Open in new tab")) { model.newTab(url: drive.url) }
                                        Divider()
                                        Button(L10n.text(volumes.isEjecting(drive) ? "Ejecting…" : "Eject")) { volumes.eject(drive) }
                                            .disabled(volumes.isEjecting(drive))
                                    }
                                    .folderDropTarget(drive.url)
                                    .hint(drive.url.path)
                            }
                        }
                    }
                }

                section(L10n.text("On this network"), count: browser.servers.count) {
                    if browser.servers.isEmpty {
                        placeholder(browser.isBrowsing ? L10n.text("Looking for file servers…") : L10n.text("No file servers found."))
                    } else {
                        grid {
                            ForEach(browser.servers) { server in
                                tile(id: "server:\(server.id)", icon: NSImage(named: NSImage.computerName) ?? FileIcons.network,
                                     title: server.name, detail: server.protocols, open: { open(server) })
                                    .contextMenu { serverMenu(server) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.content.swiftUI)
        .contentShape(Rectangle())
        .onTapGesture { selected = nil; isFocused = true }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
        .onChange(of: tab.focusListToken) { isFocused = true }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .task(id: volumes.volumes.map(\.url)) {
            let urls = volumes.volumes.map(\.url)
            usage = await Task.detached { DriveUsage.load(urls) }.value
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) (\(count))")
                .font(Theme.font.weight(.semibold))
                .foregroundStyle(Theme.text.swiftUI)
            content()
        }
    }

    private func grid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 8, alignment: .leading)],
                  alignment: .leading, spacing: 8, content: content)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(Theme.font)
            .foregroundStyle(Theme.secondaryText.swiftUI)
    }

    private func tile(id: String, icon: NSImage, title: String, detail: String, open: @escaping () -> Void) -> some View {
        NetworkTile(icon: icon, title: title, detail: detail, isSelected: selected == id)
            .onTapGesture(count: 2, perform: open)
            .simultaneousGesture(TapGesture().onEnded { selected = id; isFocused = true })
            .accessibilityAction(named: L10n.text("Open"), open)
    }

    @ViewBuilder
    private func siteMenu(_ site: SFTPSite) -> some View {
        Button(L10n.text("Open")) { model.openSite(site, in: tab) }
        Button(L10n.text("Open in new tab")) { model.openSiteInNewTab(site) }
        Divider()
        Button(L10n.text("Edit…")) { model.networkSheet = .site(site, connect: false) }
        if connections.connected.contains(site.endpoint) {
            Button(L10n.text("Disconnect")) { Task { await connections.disconnect(site.endpoint) } }
        }
        Divider()
        Button(L10n.text("Remove Site")) {
            Task { await connections.disconnect(site.endpoint) }
            sites.remove(site)
        }
    }

    @ViewBuilder
    private func serverMenu(_ server: NetworkBrowser.Server) -> some View {
        if server.offersFileSharing {
            Button(L10n.text("Connect")) { connectToShares(server) }
        }
        if server.offersSFTP {
            Button(L10n.text("New SFTP Site…")) { addSite(for: server) }
        }
    }

    /// File sharing mounts through macOS; a computer with only SSH becomes a new SFTP site.
    private func open(_ server: NetworkBrowser.Server) {
        if server.offersFileSharing {
            connectToShares(server)
        } else {
            addSite(for: server)
        }
    }

    private func connectToShares(_ server: NetworkBrowser.Server) {
        guard let url = server.sharingURL else { return }
        model.openServerAddress(url.absoluteString, in: tab)
    }

    private func addSite(for server: NetworkBrowser.Server) {
        Task {
            var site = SFTPSite()
            site.name = server.name
            site.username = NSUserName()
            if let resolved = await NetworkBrowser.resolveSFTP(server) {
                site.host = resolved.host
                site.port = resolved.port
            }
            model.networkSheet = .site(site, connect: true)
        }
    }
}

private struct NetworkTile: View {
    let icon: NSImage
    let title: String
    let detail: String
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.font)
                    .foregroundStyle(Theme.text.swiftUI)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Theme.selection.swiftUI : isHovered ? Theme.subtleHover.swiftUI : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}
