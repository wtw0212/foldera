import AppKit
import Foundation
import Testing
@testable import Foldera

@Suite(.serialized)
@MainActor
struct RemoteTransferTests {
    private func transfers(choice: NSApplication.ModalResponse = .alertSecondButtonReturn, alerts: ((String) -> Void)? = nil) -> RemoteTransfers {
        var transfers = RemoteTransfers(transfers: .shared)
        transfers.conflicts = { kind, destination in
            let resolver = ConflictResolver(kind: kind, destination: destination)
            resolver.ask = { _ in choice }
            return resolver
        }
        transfers.alert = { message, _ in alerts?(message) }
        return transfers
    }

    @Test func uploadsAndDownloadsFilesAndFolders() async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        let server = installFakeServer(endpoint)
        let file = try local.file("report.txt", contents: "12345")
        try local.file("Project/src/main.swift", contents: "print()")
        try FileManager.default.createSymbolicLink(at: local.path("Project/loop"), withDestinationURL: local.path("Project"))

        let up = await transfers().run(.copy, [file, local.path("Project")], into: endpoint.url(path: remote.url.path))
        #expect(up.error == nil && up.results == [endpoint.url(path: remote.path("report.txt").path), endpoint.url(path: remote.path("Project").path)])
        #expect(try String(contentsOf: remote.path("Project/src/main.swift"), encoding: .utf8) == "print()")
        #expect(!FileManager.default.fileExists(atPath: remote.path("Project/loop").path), "linked folders aren't followed")
        #expect(up.created.isEmpty && up.moved.isEmpty, "server changes aren't undoable")

        let downloads = try TestDirectory()
        let down = await transfers().run(.copy, [endpoint.url(path: remote.path("Project").path)], into: downloads.url)
        #expect(down.error == nil && down.results == [downloads.path("Project")])
        #expect(try String(contentsOf: downloads.path("Project/src/main.swift"), encoding: .utf8) == "print()")
        #expect(server.operations.contains("download") && server.operations.contains("upload"))
    }

    @Test func conflictsMovesAndCopiesOnOneServer() async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        let server = installFakeServer(endpoint)
        let file = try local.file("a.txt", contents: "new")
        try remote.file("a.txt", contents: "old")
        let folder = endpoint.url(path: remote.url.path)

        let keepBoth = await transfers(choice: .alertSecondButtonReturn).run(.copy, [file], into: folder)
        #expect(keepBoth.results == [endpoint.url(path: remote.path("a (2).txt").path)])
        let skip = await transfers(choice: .alertThirdButtonReturn).run(.copy, [file], into: folder)
        #expect(skip.results.isEmpty && skip.error == nil)
        let cancel = await transfers(choice: .cancel).run(.copy, [file], into: folder)
        #expect(cancel.error is CopyEngine.Cancelled)
        let replace = await transfers(choice: .alertFirstButtonReturn).run(.move, [file], into: folder)
        #expect(replace.error == nil)
        #expect(try String(contentsOf: remote.path("a.txt"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: file.path), "the local source of a move goes to the Trash")

        // Same folder: a copy gets a "- Copy" name; a move does nothing.
        let duplicate = await transfers().run(.copy, [endpoint.url(path: remote.path("a.txt").path)], into: folder)
        #expect(duplicate.results == [endpoint.url(path: remote.path("a - Copy.txt").path)])
        #expect(await transfers().run(.move, [endpoint.url(path: remote.path("a.txt").path)], into: folder).results.isEmpty)

        // Within one server, a move is a rename and a copy goes through a temporary download.
        try remote.folder("sub")
        let renamesBefore = server.operations.filter { $0 == "rename" }.count
        let moved = await transfers().run(.move, [endpoint.url(path: remote.path("a - Copy.txt").path)], into: endpoint.url(path: remote.path("sub").path))
        #expect(moved.error == nil && server.operations.filter { $0 == "rename" }.count == renamesBefore + 1)
        #expect(FileManager.default.fileExists(atPath: remote.path("sub/a - Copy.txt").path))
        let copied = await transfers().run(.copy, [endpoint.url(path: remote.path("a.txt").path)], into: endpoint.url(path: remote.path("sub").path))
        #expect(copied.error == nil && FileManager.default.fileExists(atPath: remote.path("sub/a.txt").path))

        var alerts: [String] = []
        let intoItself = await transfers(alerts: { alerts.append($0) }).run(.copy, [folder], into: endpoint.url(path: remote.path("sub").path))
        #expect(intoItself.results.isEmpty && alerts.count == 1)
    }

    @Test func failuresAndCancellationStopTheTransfer() async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        let file = try local.file("a.txt")
        server.fail("upload", with: RemoteError.failed("quota"))
        let failed = await transfers().run(.copy, [file], into: endpoint.url(path: remote.url.path))
        #expect(failed.error as? RemoteError == .failed("quota") && errors.errors.count == 1)

        server.fail("entry", with: RemoteError.failed("gone"))
        let planning = await transfers().run(.copy, [file], into: endpoint.url(path: remote.url.path))
        #expect(planning.error as? RemoteError == .failed("gone") && errors.errors.count == 2)

        let missing = await transfers().run(.copy, [endpoint.url(path: remote.path("nope").path)], into: local.url)
        #expect(missing.error as? RemoteError == .notFound("nope"))

        let progress = TransferProgress()
        let counter = ByteCounter(progress: progress)
        try counter.add(10)
        progress.cancel()
        #expect(throws: CopyEngine.Cancelled.self) { try counter.add(5) }
        #expect(counter.total == 15 && progress.completedBytes == 15)
    }

    @Test func failedTransfersLeaveNoPartialItemsAndKeepWhatTheyWouldReplace() async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        let file = try local.file("data.bin", contents: String(repeating: "x", count: 1_000))
        try remote.file("data.bin", contents: "original")
        let folder = endpoint.url(path: remote.url.path)

        server.failPartway("upload", with: RemoteError.failed("connection lost"))
        let upload = await transfers(choice: .alertFirstButtonReturn).run(.copy, [file], into: folder)
        #expect(upload.error != nil && errors.errors.count == 1)
        #expect(try String(contentsOf: remote.path("data.bin"), encoding: .utf8) == "original", "Replace keeps the original until the copy is complete")
        #expect(try FileManager.default.contentsOfDirectory(atPath: remote.url.path) == ["data.bin"], "no staging file is left")

        server.failPartway("download", with: RemoteError.failed("connection lost"))
        let downloads = try TestDirectory()
        let download = await transfers().run(.copy, [endpoint.url(path: remote.path("data.bin").path)], into: downloads.url)
        #expect(download.error != nil && download.results.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.url.path).isEmpty)

        try remote.file("tree/a.txt"); try remote.file("tree/b.txt")
        server.failPartway("download", with: RemoteError.failed("connection lost"))
        _ = await transfers().run(.move, [endpoint.url(path: remote.path("tree").path)], into: downloads.url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.url.path).isEmpty, "a half-copied folder is removed")
        #expect(FileManager.default.fileExists(atPath: remote.path("tree/b.txt").path), "a failed move keeps its source")

        let replaced = await transfers(choice: .alertFirstButtonReturn).run(.copy, [file], into: folder)
        #expect(replaced.error == nil)
        #expect(try Data(contentsOf: remote.path("data.bin")).count == 1_000)
        #expect(RemoteTransfers.stagingURL(for: remote.path("x.txt")).lastPathComponent.hasPrefix(".x.txt.foldera-"))
    }

    @Test func replacingNeverLosesTheOriginalWhenTheFinalRenameFails() async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        let file = try local.file("data.txt", contents: "new")
        try remote.file("data.txt", contents: "original")
        let folder = endpoint.url(path: remote.url.path)
        func leftovers() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: remote.url.path).sorted() }

        // Upload + Replace: original → backup succeeds, staging → final fails.
        server.fail("rename", with: RemoteError.failed("connection lost"), afterCalls: 1)
        let upload = await transfers(choice: .alertFirstButtonReturn).run(.copy, [file], into: folder)
        #expect(upload.error != nil && errors.errors.count == 1)
        #expect(try String(contentsOf: remote.path("data.txt"), encoding: .utf8) == "original")
        #expect(try leftovers() == ["data.txt"], "no staging or backup is left behind")

        // Same-server move + Replace.
        try remote.file("other/data.txt", contents: "moved")
        server.fail("rename", with: RemoteError.failed("connection lost"), afterCalls: 1)
        let move = await transfers(choice: .alertFirstButtonReturn).run(.move, [endpoint.url(path: remote.path("other/data.txt").path)], into: folder)
        #expect(move.error != nil && move.completedSources.isEmpty)
        #expect(try String(contentsOf: remote.path("data.txt"), encoding: .utf8) == "original")
        #expect(try String(contentsOf: remote.path("other/data.txt"), encoding: .utf8) == "moved")
        #expect(try leftovers() == ["data.txt", "other"])

        // Edits: the server copy survives a failed swap too.
        let fake = server
        server.fail("rename", with: RemoteError.failed("connection lost"), afterCalls: 1)
        await #expect(throws: RemoteError.failed("connection lost")) {
            try await fake.uploadAtomically(file, to: remote.path("data.txt").path) { _ in }
        }
        #expect(try String(contentsOf: remote.path("data.txt"), encoding: .utf8) == "original")
        #expect(try leftovers() == ["data.txt", "other"])

        // And when nothing fails, the old item is gone and the new one is in place.
        let replaced = await transfers(choice: .alertFirstButtonReturn).run(.move, [endpoint.url(path: remote.path("other/data.txt").path)], into: folder)
        #expect(replaced.error == nil && replaced.completedSources == [endpoint.url(path: remote.path("other/data.txt").path)])
        #expect(try String(contentsOf: remote.path("data.txt"), encoding: .utf8) == "moved")
        #expect(try leftovers() == ["data.txt", "other"])
    }

    @Test func cutAndPasteWithAServerClearsTheClipboardAndDropsRefreshTheFolder() async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory(), preferences = try TestPreferences()
        installFakeServer(endpoint)
        let folder = endpoint.url(path: remote.url.path)
        let tab = BrowserTab(url: folder, settings: AppSettings(defaults: preferences.defaults))
        try await eventually { !tab.isLoading }

        let pasteboard = NSPasteboard(name: .init("FolderaTests.\(UUID())"))
        let clipboard = FileClipboard(pasteboard: pasteboard)
        let file = try local.file("cut.txt")
        clipboard.cut([file])
        let pasted = await clipboard.paste(into: folder)
        #expect(pasted.completedSources == [file] && !FileManager.default.fileExists(atPath: file.path))
        #expect(!clipboard.canPaste && clipboard.cutURLs.isEmpty, "nothing that's gone stays on the clipboard")
        try await eventually { tab.items.map(\.name) == ["cut.txt"] }

        // Dropping onto the folder shown in a server tab refreshes it, though servers aren't watched.
        let dropped = try local.file("dropped.txt")
        #expect(FileDrop.perform([dropped], into: folder))
        try await eventually { tab.items.map(\.name).sorted() == ["cut.txt", "dropped.txt"] }
    }

    @Test func quittingWithPendingEditsAsksFirst() async throws {
        let delegate = FolderaAppDelegate()
        #expect(RemoteEditing.shared.pendingFiles.isEmpty)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test func fileTransfersHandOffRemoteWork() async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        installFakeServer(endpoint)
        let file = try local.file("handoff.txt")
        let result = await FileTransfers.shared.run(.copy, [file], into: endpoint.url(path: remote.url.path))
        #expect(result.error == nil && FileManager.default.fileExists(atPath: remote.path("handoff.txt").path))
        #expect(FileTransfers.shared.active.isEmpty)
        #expect(RemoteTransfers.name(of: endpoint.url(path: "/x/y")) == "y" && RemoteTransfers.parent(of: file) == local.url)
        #expect(RemoteTransfers.child(local.url, "z") == local.path("z"))
        #expect(!RemoteTransfers.contains(endpoint.url(path: local.url.path), local.url), "a server path never contains a local one")
    }

    @Test func pasteboardsCarryServerItemsAndDropsChooseMoveOrCopy() async throws {
        let endpoint = uniqueEndpoint(), other = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        installFakeServer(endpoint)
        let pasteboard = NSPasteboard(name: .init("FolderaTests.\(UUID())"))
        let item = endpoint.url(path: remote.path("x y.txt").path)
        let file = try local.file("f.txt")
        pasteboard.clearContents()
        pasteboard.writeObjects([ItemPasteboard.writer(for: item), ItemPasteboard.writer(for: file)])
        #expect(ItemPasteboard.urls(from: pasteboard) == [item, file] && ItemPasteboard.hasItems(pasteboard))
        #expect(pasteboard.string(forType: .URL) == nil, "Finder mustn't see server items as web links")

        let folder = endpoint.url(path: remote.url.path)
        #expect(FileDrop.operation(for: [endpoint.url(path: local.path("elsewhere/x").path)], into: folder, modifiers: []) == .move)
        #expect(FileDrop.operation(for: [other.url(path: "/x")], into: folder, modifiers: []) == .copy)
        #expect(FileDrop.operation(for: [file], into: folder, modifiers: []) == .copy)
        #expect(FileDrop.operation(for: [item], into: folder, modifiers: []) == nil, "already in that folder")
        #expect(FileDrop.operation(for: [folder], into: endpoint.url(path: remote.path("sub").path), modifiers: []) == nil)

        let clipboard = FileClipboard(pasteboard: pasteboard)
        try remote.file("x y.txt", contents: "data")
        clipboard.copy([item])
        #expect(clipboard.canPaste)
        let pasted = await clipboard.paste(into: local.url)
        #expect(pasted.results == [local.path("x y.txt")])
        #expect(try String(contentsOf: local.path("x y.txt"), encoding: .utf8) == "data")
    }
}

@Suite(.serialized)
@MainActor
struct NetworkAddressTests {
    @Test func serverAddressesOpenSitesMountSharesOrAskToSave() async throws {
        let endpoint = uniqueEndpoint(), directory = try TestDirectory(), preferences = try TestPreferences()
        let server = installFakeServer(endpoint, home: directory.url.path)
        try directory.folder("inside")
        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        var site = SFTPSite()
        site.host = endpoint.host; site.port = endpoint.port; site.username = endpoint.username
        sites.save(site)
        let model = ExplorerWindowModel(url: BrowserTab.networkURL, settings: AppSettings(defaults: preferences.defaults))
        let tab = model.activeTab
        defer { RecentServers.clear() }

        #expect(model.openServerAddress("sftp://\(endpoint.username)@\(endpoint.host):\(endpoint.port)", in: tab, sites: sites))
        try await eventually { tab.url == endpoint.url(path: directory.url.path) }
        #expect(server.operations.contains("home") && RecentServers.all().first?.hasPrefix("sftp://") == true)
        #expect(model.openServerAddress("ssh://\(endpoint.username)@\(endpoint.host):\(endpoint.port)\(directory.path("inside").path)", in: tab, sites: sites))
        #expect(tab.url == endpoint.url(path: directory.path("inside").path))

        #expect(model.openServerAddress("sftp://new.example.com:2022/srv", in: tab, sites: sites))
        guard case .site(let draft, let connect) = model.networkSheet else { Issue.record("expected the site sheet"); return }
        #expect(draft.host == "new.example.com" && draft.port == 2022 && draft.username == NSUserName() && draft.startPath == "/srv" && connect)

        var mounted: [URL] = []
        #expect(model.openServerAddress("smb://nas/share", in: tab, mount: { mounted.append($0); return directory.url }))
        try await eventually { tab.url == directory.url }
        #expect(mounted == [URL(string: "smb://nas/share")])
        #expect(!model.openServerAddress("https://example.com", in: tab, mount: { _ in directory.url }))
        #expect(model.openServerAddress("https://dav.example.com/files", in: tab, mountWebAddresses: true, mount: { _ in throw CancellationError() }))
        #expect(!model.openServerAddress("not an address", in: tab))
        #expect(!model.openServerAddress("smb://", in: tab))

        let errors = ErrorCollector()
        #expect(model.openServerAddress("afp://mac/share", in: tab, mount: { _ in throw RemoteError.failed("refused") }))
        try await eventually { errors.errors.count == 1 }

        model.openSiteInNewTab(site, activate: false)
        try await eventually { model.tabs.count == 2 && model.tabs[1].url == endpoint.url(path: directory.url.path) }
        site.startPath = directory.path("inside").path
        model.openSite(site, in: tab)
        try await eventually { tab.url == endpoint.url(path: directory.path("inside").path) }
    }

    @Test func passwordsInAddressesAreNeverStored() throws {
        let preferences = try TestPreferences()
        RecentServers.add("smb://sam:secret@nas/share", defaults: preferences.defaults)
        #expect(RecentServers.all(defaults: preferences.defaults) == ["smb://sam@nas/share"])
        preferences.defaults.set(["afp://sam:hunter2@mac/share", "smb://nas"], forKey: "recentServers")
        #expect(RecentServers.all(defaults: preferences.defaults) == ["afp://sam@mac/share", "smb://nas"])
        #expect(preferences.defaults.stringArray(forKey: "recentServers")?.joined().contains("hunter2") == false, "old history is cleaned")
        #expect(RecentServers.withoutPassword("not a url") == "not a url")

        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        let model = ExplorerWindowModel(url: BrowserTab.networkURL, settings: AppSettings(defaults: preferences.defaults))
        #expect(model.openServerAddress("sftp://sam:secret@unknown.example.com/srv", sites: sites))
        guard case .site(let draft, _) = model.networkSheet else { Issue.record("expected the site sheet"); return }
        #expect(draft.username == "sam" && sites.secrets.secret(for: "password:\(draft.id)") == nil)
    }

    @Test func recentServersAndMountHelpers() throws {
        let preferences = try TestPreferences()
        for index in 0..<10 { RecentServers.add("smb://server\(index)", defaults: preferences.defaults) }
        RecentServers.add("SMB://SERVER5", defaults: preferences.defaults)
        let recent = RecentServers.all(defaults: preferences.defaults)
        #expect(recent.count == RecentServers.limit && recent.first == "SMB://SERVER5" && !recent.contains("smb://server5"))
        RecentServers.clear(defaults: preferences.defaults)
        #expect(RecentServers.all(defaults: preferences.defaults).isEmpty)

        #expect(NetworkMounts.canMount(try #require(URL(string: "smb://nas/share"))))
        #expect(NetworkMounts.canMount(try #require(URL(string: "nfs://nas/export"))))
        #expect(!NetworkMounts.canMount(try #require(URL(string: "sftp://u@h/"))))
        #expect(!NetworkMounts.canMount(try #require(URL(string: "smb:share"))))
        #expect(NetworkMounts.webDAVURL(try #require(URL(string: "webdav://dav.example.com/x"))).absoluteString == "https://dav.example.com/x")
        #expect(NetworkMounts.webDAVURL(try #require(URL(string: "http://dav/x"))).absoluteString == "http://dav/x")
        #expect(NetworkMounts.mountedVolume(for: try #require(URL(string: "smb://no-such-server.invalid/share"))) == nil)
    }

    @Test func discoveredServersAreGroupedByComputer() {
        let browser = NetworkBrowser(canBrowse: false)
        browser.start()
        #expect(!browser.isBrowsing)
        browser.update(.smb, ["Studio", "NAS"])
        browser.update(.ssh, ["Studio"])
        browser.update(.afp, ["Old Mac"])
        #expect(browser.servers.map(\.name) == ["NAS", "Old Mac", "Studio"])
        let studio = browser.servers[2]
        #expect(studio.offersFileSharing && studio.offersSFTP && studio.protocols == "SFTP, SMB")
        #expect(studio.sharingURL?.absoluteString == "smb://Studio._smb._tcp.local")
        #expect(browser.servers[1].sharingURL?.absoluteString == "afp://Old%20Mac._afpovertcp._tcp.local")
        let sshOnly = NetworkBrowser.Server(name: "Pi", services: [.sftp])
        #expect(!sshOnly.offersFileSharing && sshOnly.sharingURL == nil && NetworkBrowser.Service.smb < .sftp)
        browser.update(.smb, [])
        #expect(browser.servers.map(\.name) == ["Old Mac", "Studio"])
        browser.stop()
    }
}
