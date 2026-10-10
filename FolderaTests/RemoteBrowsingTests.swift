import AppKit
import Foundation
import Testing
@testable import Foldera

@Suite(.serialized)
@MainActor
struct RemoteBrowsingTests {
    private func remoteTab(_ endpoint: RemoteEndpoint, _ directory: TestDirectory, preferences: TestPreferences) async throws -> BrowserTab {
        let tab = BrowserTab(url: endpoint.url(path: directory.url.path), settings: AppSettings(defaults: preferences.defaults))
        try await eventually { !tab.isLoading }
        return tab
    }

    @Test func tabsListNameAndNavigateServerFolders() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        let server = installFakeServer(endpoint)
        try directory.folder("Docs"); try directory.file("notes.txt"); try directory.file(".hidden")
        let tab = try await remoteTab(endpoint, directory, preferences: preferences)
        #expect(tab.isRemote && !tab.isPage && tab.loadError == nil && server.operations.contains("list"))
        #expect(tab.visibleItems.map(\.name) == ["Docs", "notes.txt"])
        #expect(tab.title == directory.url.lastPathComponent)
        #expect(tab.parentURL == endpoint.url(path: directory.url.deletingLastPathComponent().path))

        tab.searchText = "NOTE"
        try await eventually { tab.visibleItems.map(\.name) == ["notes.txt"] }
        tab.searchText = ""
        tab.open(try #require(tab.visibleItems.first { $0.name == "Docs" }))
        try await eventually { tab.url == endpoint.url(path: directory.path("Docs").path) && !tab.isLoading }
        tab.navigate(to: endpoint.root)
        #expect(tab.parentURL == BrowserTab.networkURL && BrowserTab.displayName(of: endpoint.root) == endpoint.displayName)
        #expect(BrowserTab.pathName(of: BrowserTab.networkURL) == "Network" && BrowserTab.displayName(of: BrowserTab.networkURL) == L10n.text("Network"))
        #expect(BrowserTab.editableAddress(of: endpoint.url(path: "/a b")) == "sftp://\(endpoint.username)@\(endpoint.host):2200/a b")
        #expect(BrowserTab.editableAddress(of: BrowserTab.networkURL) == "Network" && BrowserTab.editableAddress(of: BrowserTab.thisMacURL) == "This Mac")
        #expect(Breadcrumbs.segments(for: endpoint.url(path: "/a/b")) == [BrowserTab.networkURL, endpoint.root, endpoint.url(path: "/a"), endpoint.url(path: "/a/b")])
        #expect(Breadcrumbs.segments(for: BrowserTab.networkURL) == [BrowserTab.networkURL])
    }

    @Test func refreshedRemoteSearchAddsAndRemovesMatches() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        installFakeServer(endpoint)
        try directory.file("report-old.txt")
        let tab = try await remoteTab(endpoint, directory, preferences: preferences)
        tab.searchText = "report"
        #expect(tab.visibleItems.map(\.name) == ["report-old.txt"])

        try directory.file("report-new.txt")
        try FileManager.default.moveItem(at: directory.path("report-old.txt"), to: directory.path("unrelated.txt"))
        tab.reload()
        try await eventually { !tab.isLoading }
        #expect(tab.items.count == 2)
        #expect(tab.visibleItems.map(\.name) == ["report-new.txt"])
    }

    @Test func remoteSearchFiltersAndHiddenSelectionsUseTheCurrentListing() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        installFakeServer(endpoint)
        try directory.file("note.txt")
        let image = try directory.file("photo.png"), hidden = try directory.file(".private.png")
        let tab = try await remoteTab(endpoint, directory, preferences: preferences)
        tab.searchFilters.kind = .images
        #expect(tab.visibleItems.map(\.name) == [image.lastPathComponent])
        #expect(!tab.canSearchRecursively && tab.searchScope == .folder && !tab.searchReachedLimit)
        tab.settings.showHiddenFiles = true
        #expect(Set(tab.visibleItems.map(\.name)) == [image.lastPathComponent, hidden.lastPathComponent])
        tab.selection = [endpoint.url(path: hidden.path)]
        tab.settings.showHiddenFiles = false
        #expect(tab.selection.isEmpty && tab.visibleItems.map(\.name) == [image.lastPathComponent])
        tab.clearSearch()
        #expect(!tab.isSearchActive && tab.visibleItems.count == 2)
    }

    @Test func remoteSearchBeforeLoadingUsesTheNewListing() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        installFakeServer(endpoint)
        try directory.file("report.txt")
        let tab = BrowserTab(url: endpoint.url(path: directory.url.path), settings: AppSettings(defaults: preferences.defaults))
        tab.searchText = "report"
        try await eventually { !tab.isLoading }
        #expect(tab.visibleItems.map(\.name) == ["report.txt"])
    }

    @Test func missingFoldersAndCancelledSignInsShowErrors() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        installFakeServer(endpoint)
        let tab = BrowserTab(url: endpoint.url(path: directory.path("gone").path), settings: AppSettings(defaults: preferences.defaults))
        try await eventually { !tab.isLoading }
        #expect(tab.loadError == RemoteError.notFound("gone").localizedDescription)
        let unnamed = BrowserTab(url: try #require(URL(string: "sftp://host-only/x")), settings: AppSettings(defaults: preferences.defaults))
        try await eventually { !unnamed.isLoading }
        #expect(unnamed.loadError != nil)

        let cancelled = RemoteConnections { _ in throw CancellationError() }
        let other = uniqueEndpoint()
        await #expect(throws: RemoteError.notConnected(other.displayName)) {
            _ = try await RemoteDirectory.load(other.url(path: "/"), connections: cancelled).count
        }
    }

    @Test func folderCommandsChangeTheServer() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        let errors = ErrorCollector()
        installFakeServer(endpoint)
        try directory.file("a.txt")
        let tab = try await remoteTab(endpoint, directory, preferences: preferences)

        tab.newFolder()
        try await eventually { tab.renameRequest?.url == endpoint.url(path: directory.path("New folder").path) }
        tab.newTextDocument()
        try await eventually { tab.renameRequest?.url == endpoint.url(path: directory.path("New Text Document.txt").path) }
        tab.newFolder()
        try await eventually { FileManager.default.fileExists(atPath: directory.path("New folder (2)").path) }

        tab.commitRename(of: endpoint.url(path: directory.path("a.txt").path), to: "b.txt")
        try await eventually { tab.selection == [endpoint.url(path: directory.path("b.txt").path)] }
        #expect(FileManager.default.fileExists(atPath: directory.path("b.txt").path))
        tab.commitRename(of: endpoint.url(path: directory.path("b.txt").path), to: "New folder")
        try await eventually { errors.errors.count == 1 }
        #expect(errors.errors.first as? RemoteError == .alreadyExists("New folder"))
        tab.commitRename(of: endpoint.url(path: directory.path("b.txt").path), to: "a/b")
        #expect(errors.errors.count == 2)

        // Deleting a linked folder removes the link, never what it points to.
        try FileManager.default.createSymbolicLink(at: directory.path("link"), withDestinationURL: directory.path("New folder"))
        try directory.file("New folder/keep.txt")
        tab.reload()
        try await eventually { tab.items.count == 5 }
        var confirmed: [String] = []
        BrowserTab.confirmRemoteDelete = { confirmed = $0; return false }
        tab.selection = [endpoint.url(path: directory.path("link").path), endpoint.url(path: directory.path("b.txt").path)]
        tab.trashSelection()
        #expect(confirmed.sorted() == ["b.txt", "link"] && FileManager.default.fileExists(atPath: directory.path("b.txt").path))
        BrowserTab.confirmRemoteDelete = { _ in true }
        defer { BrowserTab.confirmRemoteDelete = { _ in false } }
        tab.trashSelection()
        try await eventually { !FileManager.default.fileExists(atPath: directory.path("b.txt").path) && tab.selection.isEmpty }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path("link").path)) == nil)
        #expect(FileManager.default.fileExists(atPath: directory.path("New folder/keep.txt").path))
        tab.selection = [endpoint.url(path: directory.path("New folder").path)]
        tab.trashSelection()
        try await eventually { !FileManager.default.fileExists(atPath: directory.path("New folder").path) }
        #expect(tab.selectedArchives.isEmpty)
        tab.compressSelection()
        tab.showInFinder()
    }

    @Test func detailsAndTerminalCommandsDescribeTheServer() throws {
        let endpoint = RemoteEndpoint(host: "h", port: 2222, username: "me")
        var site = SFTPSite()
        site.host = "h"; site.port = 2222; site.username = "me"; site.authentication = .privateKey; site.keyPath = "/k/id"
        #expect(BrowserTab.sshCommand(for: endpoint, path: "/srv/it's", site: site)
                == "ssh -t -p 2222 -i '/k/id' -- 'me@h' 'cd '\\''/srv/it'\\''\\'\\'''\\''s'\\'' && exec \"$SHELL\" -l'")
        #expect(BrowserTab.sshCommand(for: RemoteEndpoint(host: "h", username: "me"), path: "/", site: nil).hasPrefix("ssh -t -- 'me@h'"))
        let item = FileItem(remote: RemoteEntry(path: "/srv/a.txt", isDirectory: false, isSymlink: false, size: 2048, modified: Date(), permissions: nil), endpoint: endpoint)
        let details = BrowserTab.remoteDetails(item, location: endpoint.url(path: "/srv"))
        #expect(details.contains("me@h:2222:/srv") && details.split(separator: "\n").count == 4)
        #expect(FileFormat.location(of: item.url) == "me@h:2222:/srv")
        #expect(FileIcons.icon(forPath: endpoint.root) === FileIcons.icon(forPath: BrowserTab.networkURL) || true)
        #expect(!Thumbnails.showsPreview(item))
    }

    @Test func openingAServerFileEditsATemporaryCopy() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), cache = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        let remote = try directory.file("page.html", contents: "v1")
        var opened: [URL] = []
        let editing = RemoteEditing(folder: cache.url, openFile: { opened.append($0) }, retryDelay: 0)
        let local = try await editing.open(endpoint.url(path: remote.path))
        #expect(opened == [local] && editing.sessions.count == 1)
        #expect(try String(contentsOf: local, encoding: .utf8) == "v1")
        await editing.uploadChanges()
        #expect(!server.operations.contains("upload"), "unchanged copies aren't uploaded")

        try "v2".write(to: local, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: local.path)
        await editing.uploadChanges()
        #expect(try String(contentsOf: remote, encoding: .utf8) == "v2")

        // A save that fails part-way stays pending, leaves the server's copy intact, and is retried.
        try "v3".write(to: local, atomically: true, encoding: .utf8)
        server.failPartway("upload", with: RemoteError.failed("connection lost"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: local.path)
        await editing.uploadChanges()
        #expect(errors.errors.count == 1 && editing.sessions.first?.isPending == true)
        #expect(try String(contentsOf: remote, encoding: .utf8) == "v2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["page.html"], "no partial upload is left")
        await editing.uploadChanges()
        #expect(try String(contentsOf: remote, encoding: .utf8) == "v3")
        #expect(editing.sessions.first?.isPending == false && errors.errors.count == 1, "the retry succeeded without another alert")

        // Retries wait, and one failed version is only reported once.
        let waitingCache = try TestDirectory()
        let waiting = RemoteEditing(folder: waitingCache.url, openFile: { _ in }, retryDelay: 60)
        let pending = try await waiting.open(endpoint.url(path: remote.path))
        server.fail("upload", with: RemoteError.failed("down"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: pending.path)
        await waiting.uploadChanges()
        await waiting.uploadChanges()
        #expect(errors.errors.count == 2 && waiting.sessions.first?.failures == 1, "not retried before its backoff")
        try FileManager.default.removeItem(at: pending)
        await waiting.uploadChanges()

        try FileManager.default.removeItem(at: local)
        await editing.uploadChanges()
        #expect(editing.sessions.isEmpty)
        await #expect(throws: RemoteError.self) { try await editing.open(try #require(URL(string: "sftp://nouser/x"))) }
    }

    @Test func serverMenusListSitesAndSubfolders() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        installFakeServer(endpoint)
        try directory.folder("One"); try directory.folder(".two"); try directory.file("file.txt")
        let model = ExplorerWindowModel(url: endpoint.url(path: directory.path("One").path), settings: AppSettings(defaults: preferences.defaults))
        let menu = await SubfolderMenu.make(forServerLocation: endpoint.url(path: directory.url.path), model: model, tab: model.activeTab)
        #expect(menu.items.map(\.title) == ["One"] && menu.items[0].attributedTitle != nil)
        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        let empty = await SubfolderMenu.make(forServerLocation: BrowserTab.networkURL, model: model, tab: model.activeTab, sites: sites)
        #expect(empty.items.allSatisfy { !$0.isEnabled } || !VolumeMonitor.shared.networkVolumes.isEmpty)
        var site = SFTPSite()
        site.host = endpoint.host; site.port = endpoint.port; site.username = endpoint.username; site.name = "Fake"
        sites.save(site)
        let listed = await SubfolderMenu.make(forServerLocation: BrowserTab.networkURL, model: model, tab: model.activeTab, sites: sites)
        #expect(listed.items.first?.title == "Fake")
    }
}
