import AppKit
import SwiftUI
import Testing
import ViewInspector
@testable import Foldera

@Suite(.serialized)
@MainActor
struct NetworkViewTests {
    private struct Fixture {
        let preferences: TestPreferences
        let model: ExplorerWindowModel
        let sites: SFTPSites
        let connections: RemoteConnections
        let browser: NetworkBrowser
        let site: SFTPSite
    }

    private func fixture(connected: Bool = true) throws -> Fixture {
        let preferences = try TestPreferences()
        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        var site = SFTPSite()
        site.name = "Web server"; site.host = "web.example.com"; site.username = "deploy"
        sites.save(site, password: "pw")
        let connections = RemoteConnections { _ in FakeRemoteFileSystem() }
        if connected { connections.install(FakeRemoteFileSystem(), for: site.endpoint) }
        let browser = NetworkBrowser(canBrowse: false)
        browser.update(.smb, ["NAS"])
        browser.update(.sftp, ["Raspberry Pi"])
        let model = ExplorerWindowModel(url: BrowserTab.networkURL, settings: AppSettings(defaults: preferences.defaults))
        return Fixture(preferences: preferences, model: model, sites: sites, connections: connections, browser: browser, site: site)
    }

    private func texts<V: View>(_ view: V) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func networkPageListsSitesDrivesAndServers() throws {
        let f = try fixture()
        let view = NetworkView(model: f.model, tab: f.model.activeTab, sites: f.sites, connections: f.connections, browser: f.browser)
        let labels = try texts(view)
        #expect(labels.contains("\(L10n.text("SFTP sites")) (1)") && labels.contains("\(L10n.text("On this network")) (2)"))
        #expect(labels.contains("Web server") && labels.contains(L10n.format("%@ · Connected", "deploy@web.example.com")))
        #expect(labels.contains("NAS") && labels.contains("Raspberry Pi") && labels.contains("SMB") && labels.contains("SFTP"))
        try view.inspect().find(button: L10n.text("Connect to Server…")).tap()
        #expect(f.model.networkSheet == .connect(""))
        try view.inspect().find(button: L10n.text("New SFTP Site…")).tap()
        guard case .site(let draft, true) = f.model.networkSheet else { Issue.record("expected a new site"); return }
        #expect(draft.host.isEmpty)

        let empty = NetworkView(model: f.model, tab: f.model.activeTab, sites: SFTPSites(defaults: f.preferences.defaults.emptyCopy(), secrets: MemorySecrets()),
                                connections: f.connections, browser: NetworkBrowser(canBrowse: false))
        let emptyLabels = try texts(empty)
        #expect(emptyLabels.contains(L10n.text("Add a site to browse a server over SFTP.")))
        #expect(emptyLabels.contains(L10n.text("No file servers found.")))
    }

    @Test func networkPageRendersInTheWindowWithItsSheets() async throws {
        let f = try fixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ExplorerWindow(model: f.model, settings: AppSettings(defaults: f.preferences.defaults)))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        for sheet in [NetworkSheet.connect("smb://nas"), .site(f.site, connect: false)] {
            f.model.networkSheet = sheet
            try await eventually { window.attachedSheet != nil }
            f.model.networkSheet = nil
            try await eventually { window.attachedSheet == nil }
        }
        let pane = NSHostingView(rootView: NavigationPane(model: f.model, tab: f.model.activeTab, sites: f.sites, connections: f.connections))
        pane.frame = NSRect(x: 0, y: 0, width: 240, height: 800)
        pane.layoutSubtreeIfNeeded()
        #expect(pane.fittingSize.height > 0)
        let labels = try texts(NavigationPane(model: f.model, tab: f.model.activeTab, sites: f.sites, connections: f.connections))
        #expect(labels.contains(L10n.text("Network")) && labels.contains("Web server"))
        let standalone = NSHostingView(rootView: NetworkView(model: f.model, tab: f.model.activeTab, sites: f.sites, connections: f.connections, browser: f.browser))
        standalone.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        standalone.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(standalone.fittingSize.height > 0)
    }

    @Test func siteEditorSavesSitesAndForgetsPasswords() throws {
        let f = try fixture(connected: false)
        var opened: [SFTPSite] = []
        var site = f.site
        site.name = "Renamed"
        let existing = SiteEditorSheet(site: site, connect: false, sites: f.sites) { opened.append($0) }
        let labels = try texts(existing)
        #expect(labels.contains(L10n.format("Edit “%@”", "Renamed")) && !labels.contains(L10n.text("Save and Connect")))
        try existing.inspect().find(button: L10n.text("Forget Saved Password")).tap()
        #expect(f.sites.password(for: f.site) == nil)
        try existing.inspect().find(button: L10n.text("Save")).tap()
        #expect(f.sites.sites.map(\.name) == ["Renamed"] && opened.isEmpty)

        var draft = SFTPSite()
        draft.host = " new.example.com "; draft.username = "me"; draft.authentication = .privateKey; draft.keyPath = "~/.ssh/id_ed25519"
        let new = SiteEditorSheet(site: draft, connect: true, sites: f.sites) { opened.append($0) }
        let newLabels = try texts(new)
        #expect(newLabels.contains(L10n.text("New SFTP Site")))
        #expect(newLabels.contains(L10n.text("Ed25519 or RSA keys in OpenSSH format. Foldera asks for the passphrase if the key has one.")))
        try new.inspect().find(button: L10n.text("Save and Connect")).tap()
        #expect(opened.map(\.host) == ["new.example.com"] && f.sites.sites.count == 2)
        try new.inspect().find(button: L10n.text("Save")).tap()
        #expect(opened.count == 1 && f.sites.sites.count == 2, "Save alone doesn't connect")
    }

    @Test func connectSheetOpensTypedAddressesAndRemembersRecentOnes() throws {
        let f = try fixture()
        RecentServers.clear()
        RecentServers.add("smb://nas/share")
        defer { RecentServers.clear() }
        let sheet = ConnectServerSheet(model: f.model, address: "sftp://someone@unknown.example.com/srv")
        let labels = try texts(sheet)
        #expect(labels.contains(L10n.text("Connect to Server")) && labels.contains("smb://nas/share"))
        try sheet.inspect().find(button: L10n.text("Connect")).tap()
        guard case .site(let draft, true) = f.model.networkSheet else { Issue.record("expected the site sheet"); return }
        #expect(draft.host == "unknown.example.com" && draft.username == "someone")
        try sheet.inspect().find(button: L10n.text("Clear Recent")).tap()
        #expect(RecentServers.all().isEmpty)

        let errors = ErrorCollector()
        try ConnectServerSheet(model: f.model, address: "ftp://files.example.com").inspect().find(button: L10n.text("Connect")).tap()
        #expect(errors.errors.count == 1)
    }

    @Test func remoteTabsHideLocalOnlyCommands() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        installFakeServer(endpoint)
        try directory.file("a.txt"); try directory.folder("f")
        let tab = BrowserTab(url: endpoint.url(path: directory.url.path), settings: AppSettings(defaults: preferences.defaults))
        try await eventually { tab.items.count == 2 }
        tab.selection = [endpoint.url(path: directory.path("a.txt").path)]
        let titles = ContextMenus.itemMenu(tab: tab) { _ in }.items.map(\.title)
        #expect(!titles.contains(L10n.text("Open with")) && !titles.contains(L10n.text("Compress to ZIP file")) && !titles.contains(L10n.text("Show in Finder")))
        tab.selection = [endpoint.url(path: directory.path("f").path)]
        #expect(!ContextMenus.itemMenu(tab: tab) { _ in }.items.map(\.title).contains(L10n.text("Pin to Quick access")))
        let background = ContextMenus.backgroundMenu(tab: tab).items.map(\.title)
        #expect(background.contains(L10n.text("Open in Terminal (SSH)")) && !background.contains(L10n.text("Pin to Quick access")))
        #expect(!FolderDropTarget.acceptsDrops(BrowserTab.networkURL) && FolderDropTarget.acceptsDrops(directory.url))
    }
}

private extension UserDefaults {
    /// A fresh empty suite, for views that need a second, empty store.
    func emptyCopy() -> UserDefaults { UserDefaults(suiteName: "FolderaTests.empty.\(UUID())")! }
}
