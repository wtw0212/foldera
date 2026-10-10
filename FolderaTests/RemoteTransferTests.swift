import AppKit
import Foundation
import Testing
@testable import Foldera

@Suite(.serialized)
@MainActor
struct RemoteTransferTests {
    nonisolated enum Direction: CaseIterable, Sendable { case upload, download, betweenServers }
    nonisolated enum ReplacementKind: CaseIterable, Sendable { case edit, copy, move }

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

    @Test(arguments: [UInt32(0o600), 0o755])
    func editingReplacementPreservesPermissions(permissions: UInt32) async throws {
        let local = try TestDirectory(), remote = try TestDirectory()
        let original = try remote.file("private.txt", contents: "OLD")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: original.path)
        let replacement = try local.file("new.txt", contents: "NEW")
        let endpoint = uniqueEndpoint(), server = FakeRemoteFileSystem()
        let connections = RemoteConnections { _ in server }
        try await connections.upload(replacement, replacing: original.path, on: endpoint) { _ in }
        #expect(try String(contentsOf: original, encoding: .utf8) == "NEW")
        #expect(try await server.entry(at: original.path)?.permissions == permissions)
    }

    @Test func permissionFailureKeepsTheOriginalAndCleansStaging() async throws {
        let local = try TestDirectory(), remote = try TestDirectory()
        let original = try remote.file("private.txt", contents: "KEEP")
        let replacement = try local.file("new.txt", contents: "NEW")
        let server = FakeRemoteFileSystem()
        server.fail("setPermissions", with: RemoteError.failed("permission denied"))
        let connections = RemoteConnections { _ in server }
        await #expect(throws: RemoteError.self) {
            try await connections.upload(replacement, replacing: original.path, on: uniqueEndpoint()) { _ in }
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "KEEP")
        #expect(try FileManager.default.contentsOfDirectory(atPath: remote.url.path) == ["private.txt"])
    }

    @Test func editingReplacementRefusesSymbolicLinks() async throws {
        let local = try TestDirectory(), remote = try TestDirectory()
        let original = try remote.file("target", contents: "KEEP")
        let link = remote.path("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let replacement = try local.file("new", contents: "NEW")
        let server = FakeRemoteFileSystem(), connections = RemoteConnections { _ in server }
        await #expect(throws: RemoteError.self) {
            try await connections.upload(replacement, replacing: link.path, on: uniqueEndpoint()) { _ in }
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == original.path)
        #expect(try String(contentsOf: original, encoding: .utf8) == "KEEP")
        #expect(!server.operations.contains("upload"))
    }

    @Test func remoteSizePreparationStopsAfterCancellation() async throws {
        let remote = try TestDirectory()
        try remote.file("nested/file.txt")
        let progress = TransferProgress()
        let server = FakeRemoteFileSystem(beforeList: { progress.cancel() })
        let entry = try #require(try await server.entry(at: remote.url.path))
        await #expect(throws: CopyEngine.Cancelled.self) { try await server.totalSize(entry, progress: progress) }
        #expect(server.operations.filter { $0 == "list" }.count == 1)
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

    @Test(arguments: Direction.allCases)
    func movesNeverDiscardDirectoryLinks(_ direction: Direction) async throws {
        let endpoint = uniqueEndpoint(), other = uniqueEndpoint()
        let source = try TestDirectory(), destination = try TestDirectory(), linked = try TestDirectory()
        let errors = ErrorCollector()
        installFakeServer(endpoint)
        installFakeServer(other)
        let tree = try source.folder("tree")
        try source.file("tree/report.txt")
        let link = source.path("tree/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linked.url)
        try destination.file("tree/original.txt", contents: "original")
        let sourceURL = direction == .upload ? tree : endpoint.url(path: tree.path)
        let destinationURL: URL = switch direction {
        case .upload: endpoint.url(path: destination.url.path)
        case .download: destination.url
        case .betweenServers: other.url(path: destination.url.path)
        }
        let pasteboard = NSPasteboard(name: .init("FolderaTests.\(UUID())"))
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.cut([sourceURL])
        let changeCount = pasteboard.changeCount

        let result = await transfers(choice: .alertFirstButtonReturn).run(.move, [sourceURL], into: destinationURL)
        clipboard.finishMove(result, urls: [sourceURL], changeCount: changeCount)
        #expect(result.error != nil && errors.errors.count == 1)
        #expect(result.results.isEmpty && result.completedSources.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == linked.url.path)
        #expect(FileManager.default.fileExists(atPath: source.path("tree/report.txt").path))
        #expect(try String(contentsOf: destination.path("tree/original.txt"), encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path) == ["tree"], "staging is removed")
        #expect(clipboard.cutURLs == [sourceURL] && clipboard.canPaste, "a move that never committed remains on Cut")
    }

    @Test func downloadsReuseDirectoryListingMetadata() async throws {
        let endpoint = uniqueEndpoint(), source = try TestDirectory(), destination = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        for index in 0..<12 { try source.file("tree/file-\(index).txt", contents: "data") }
        let result = await transfers().run(.copy, [endpoint.url(path: source.path("tree").path)], into: destination.url)
        #expect(result.error == nil && errors.errors.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path("tree").path).count == 12)
        #expect(server.operations.filter { $0 == "download" }.count == 12)
        #expect(server.operations.filter { $0 == "list" }.count <= 6, "directory listings must not grow with the number of files")
    }

    @Test(arguments: [false, true])
    func bulkRemoteCopiesListTheSourceParentOnce(betweenServers: Bool) async throws {
        let endpoint = uniqueEndpoint(), other = uniqueEndpoint()
        let source = try TestDirectory(), destination = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        installFakeServer(other)
        var selected: [URL] = []
        for index in 0..<1_000 {
            let file = try source.file("file-\(index).txt", contents: "data-\(index)")
            if index < 100 { selected.append(endpoint.url(path: file.path)) }
        }
        let folder = betweenServers ? other.url(path: destination.url.path) : destination.url

        let result = await transfers().run(.copy, selected, into: folder)
        #expect(result.error == nil && errors.errors.isEmpty && result.results.count == 100)
        #expect(server.operations.filter { $0 == "download" }.count == 100)
        #expect(server.operations.filter { $0 == "list" }.count == 1,
                "planning, sizing and downloading must reuse a single parent listing")
        for index in 0..<100 {
            #expect(try String(contentsOf: destination.path("file-\(index).txt"), encoding: .utf8) == "data-\(index)")
        }
    }

    @Test func sourceMetadataIsGroupedByEndpointAndParent() async throws {
        let endpoint = uniqueEndpoint(), other = uniqueEndpoint()
        let source = try TestDirectory(), destination = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint), otherServer = installFakeServer(other)
        var selected: [URL] = []
        for index in 0..<12 {
            let parent = index < 8 ? "first" : "second"
            let file = try source.file("\(parent)/file-\(index).txt", contents: "data-\(index)")
            let host = index < 4 ? other : endpoint
            selected.append(host.url(path: file.path))
        }

        let result = await transfers().run(.copy, selected, into: destination.url)
        #expect(result.error == nil && errors.errors.isEmpty && result.results.count == 12)
        #expect(server.operations.filter { $0 == "list" }.count == 2)
        #expect(otherServer.operations.filter { $0 == "list" }.count == 1,
                "identical parent paths on different servers have distinct metadata")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path).count == 12)
    }

    @Test func sourceMetadataIsNotReusedAcrossTransfers() async throws {
        let endpoint = uniqueEndpoint(), source = try TestDirectory(), destination = try TestDirectory()
        let linked = try TestDirectory(), errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        let file = try source.file("item", contents: "original")
        let remote = endpoint.url(path: file.path)
        let transfers = transfers(choice: .alertFirstButtonReturn)
        let first = await transfers.run(.copy, [remote], into: destination.url)
        #expect(first.error == nil && first.results == [destination.path("item")])
        try FileManager.default.removeItem(at: file)
        try linked.file("data.txt", contents: "linked data")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: linked.url)

        let second = await transfers.run(.copy, [remote], into: destination.url)
        #expect(second.error == nil && errors.errors.isEmpty && second.results.isEmpty)
        #expect(server.operations.filter { $0 == "list" }.count == 2)
        #expect(try String(contentsOf: destination.path("item"), encoding: .utf8) == "original")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == linked.url.path)
    }

    @Test(arguments: [false, true])
    func directRemoteDirectoryLinksAreNotDereferencedOnARealServer(moving: Bool) async throws {
        let server = try LocalSSHServer(), source = try TestDirectory(), destination = try TestDirectory()
        let target = try source.folder("target")
        try source.file("target/data.txt", contents: "original")
        let link = source.path("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let system = try await server.connect()
        let connections = RemoteConnections { _ in throw RemoteError.failed("unexpected login") }
        connections.install(system, for: server.endpoint)
        let errors = ErrorCollector()
        var transfers = transfers()
        transfers.connections = connections

        let result = await transfers.run(moving ? .move : .copy, [server.endpoint.url(path: link.path)], into: destination.url)
        #expect((result.error != nil) == moving && errors.errors.count == (moving ? 1 : 0))
        #expect(result.results.isEmpty && result.completedSources.isEmpty && result.consumedCutSources.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path).isEmpty)
        #expect(try String(contentsOf: source.path("target/data.txt"), encoding: .utf8) == "original")
        await connections.disconnect(server.endpoint)
    }

    @Test(arguments: Direction.allCases, [false, true])
    func directDirectoryLinksAreRejectedOrOmitted(_ direction: Direction, moving: Bool) async throws {
        let endpoint = uniqueEndpoint(), other = uniqueEndpoint()
        let source = try TestDirectory(), destination = try TestDirectory(), linked = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint), otherServer = installFakeServer(other)
        try linked.file("data.txt", contents: "linked data")
        let link = source.path("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linked.url)
        try destination.file("shortcut/original.txt", contents: "original")
        let sourceURL = direction == .upload ? link : endpoint.url(path: link.path)
        let destinationURL: URL = switch direction {
        case .upload: endpoint.url(path: destination.url.path)
        case .download: destination.url
        case .betweenServers: other.url(path: destination.url.path)
        }

        let result = await transfers(choice: .alertFirstButtonReturn).run(moving ? .move : .copy, [sourceURL], into: destinationURL)
        #expect((result.error != nil) == moving && errors.errors.count == (moving ? 1 : 0))
        #expect(result.results.isEmpty && result.completedSources.isEmpty && result.consumedCutSources.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == linked.url.path)
        #expect(try String(contentsOf: linked.path("data.txt"), encoding: .utf8) == "linked data")
        #expect(try String(contentsOf: destination.path("shortcut/original.txt"), encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path) == ["shortcut"])
        #expect(!server.operations.contains("download") && !server.operations.contains("upload"))
        #expect(!otherServer.operations.contains("upload"), "a rejected or omitted link never starts copying")
    }

    @Test(arguments: Direction.allCases)
    func copiesOmitSelectedDirectoryLinksButContinueWithOtherItems(_ direction: Direction) async throws {
        let endpoint = uniqueEndpoint(), other = uniqueEndpoint()
        let source = try TestDirectory(), destination = try TestDirectory(), linked = try TestDirectory()
        let errors = ErrorCollector()
        installFakeServer(endpoint)
        installFakeServer(other)
        let link = source.path("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linked.url)
        let file = try source.file("file.txt", contents: "keep")
        let sources = direction == .upload ? [link, file] : [link, file].map { endpoint.url(path: $0.path) }
        let destinationURL: URL = switch direction {
        case .upload: endpoint.url(path: destination.url.path)
        case .download: destination.url
        case .betweenServers: other.url(path: destination.url.path)
        }

        let result = await transfers().run(.copy, sources, into: destinationURL)
        #expect(result.error == nil && errors.errors.isEmpty && result.results == [RemoteTransfers.child(destinationURL, "file.txt")])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path) == ["file.txt"])
        #expect(try String(contentsOf: destination.path("file.txt"), encoding: .utf8) == "keep")
    }

    @Test func sameServerCopiesOmitDirectoryLinksButMovesRenameThem() async throws {
        let endpoint = uniqueEndpoint(), source = try TestDirectory(), destination = try TestDirectory(), linked = try TestDirectory()
        let errors = ErrorCollector()
        let system = installFakeServer(endpoint)
        let link = source.path("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linked.url)
        let sources = [endpoint.url(path: link.path)], folder = endpoint.url(path: destination.url.path)
        let copied = await transfers().run(.copy, sources, into: folder)
        #expect(copied.error == nil && copied.results.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path).isEmpty)
        let result = await transfers().run(.move, sources, into: folder)
        #expect(result.error == nil && errors.errors.isEmpty && result.completedSources == [endpoint.url(path: link.path)])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path("shortcut").path) == linked.url.path)
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(!system.operations.contains("download") && !system.operations.contains("upload"))
    }

    @Test(arguments: [false, true])
    func committedMovesCannotReplayAfterPartialSourceDeletion(betweenServers: Bool) async throws {
        let endpoint = uniqueEndpoint(), other = uniqueEndpoint()
        let source = try TestDirectory(), destination = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        installFakeServer(other)
        try source.file("tree/a.txt", contents: "alpha")
        try source.file("tree/b.txt", contents: "beta")
        let sourceURL = endpoint.url(path: source.path("tree").path)
        let destinationURL = betweenServers ? other.url(path: destination.url.path) : destination.url
        let committed = RemoteTransfers.child(destinationURL, "tree")
        let pasteboard = NSPasteboard(name: .init("FolderaTests.\(UUID())"))
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.cut([sourceURL])
        server.fail("removeFile", with: RemoteError.failed("permission"), afterCalls: 1)

        let result = await clipboard.paste(into: destinationURL)
        #expect(result.error as? RemoteError == .failed("permission") && errors.errors.count == 1)
        #expect(result.results == [committed] && result.completedSources.isEmpty)
        #expect(FileChange(result, kind: .move).isEmpty, "server transfers must not be passed to local Undo")
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path("tree").path).count == 1)
        #expect(try String(contentsOf: destination.path("tree/a.txt"), encoding: .utf8) == "alpha")
        #expect(try String(contentsOf: destination.path("tree/b.txt"), encoding: .utf8) == "beta")
        try #require(!clipboard.canPaste && clipboard.cutURLs.isEmpty, "the damaged source must not be pasted again")
        #expect(await clipboard.paste(into: destinationURL).results.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path("tree").path).count == 2)
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
        let staging = try await transfers().stagingURL(for: endpoint.url(path: remote.path("x.txt").path))
        let stagingDirectory = staging.deletingLastPathComponent()
        #expect(staging.lastPathComponent == "payload")
        #expect(stagingDirectory.lastPathComponent.hasPrefix(".foldera-") && stagingDirectory.lastPathComponent.hasSuffix(".part"))
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
        server.fail("rename", with: RemoteError.failed("connection lost"), afterCalls: 1)
        await #expect(throws: RemoteError.failed("connection lost")) {
            try await RemoteConnections.shared.upload(file, replacing: remote.path("data.txt").path, on: endpoint) { _ in }
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

    @Test(arguments: ReplacementKind.allCases)
    func destinationRacesPreserveAllCopiesAndJournal(kind: ReplacementKind) async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        let preferences = try TestPreferences(), errors = ErrorCollector()
        let target = try remote.file("data.txt", contents: "original")
        let localSource = try local.file("data.txt", contents: "replacement")
        let moveSource = try remote.file("source/data.txt", contents: "replacement")
        let backup = remote.path(".foldera-BACKUP.old/payload")
        let server = FakeRemoteFileSystem(beforeRename: { path, destination in
            if destination == target.path, !RemotePath.parent(of: path).hasSuffix(".old") {
                try Data("other client's data".utf8).write(to: target)
            }
        })
        let journal = SwapJournal(defaults: preferences.defaults)
        let connections = RemoteConnections(connector: { _ in server.reconnect() }, journal: journal)
        connections.uniqueToken = { "BACKUP" }
        var failure: Error?
        if kind == .edit {
            do {
                try await connections.upload(localSource, replacing: target.path, on: endpoint) { _ in }
            } catch { failure = error }
        } else {
            var transfer = transfers(choice: .alertFirstButtonReturn)
            transfer.connections = connections
            let source = kind == .move ? endpoint.url(path: moveSource.path) : localSource
            let result = await transfer.run(kind == .move ? .move : .copy, [source], into: endpoint.url(path: remote.url.path))
            failure = result.error
            #expect(result.results.isEmpty && result.completedSources.isEmpty && result.consumedCutSources.isEmpty)
            #expect(errors.errors.count == 1)
        }
        #expect(failure != nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "other client's data")
        #expect(try String(contentsOf: localSource, encoding: .utf8) == "replacement")
        #expect(try String(contentsOf: moveSource, encoding: .utf8) == "replacement")
        #expect(FileOperations.exists(backup), "the original must survive the failed final rename")
        if FileOperations.exists(backup) { #expect(try String(contentsOf: backup, encoding: .utf8) == "original") }
        #expect(journal.swaps.count == 1, "an unresolved conflict must retain its recovery record")
        #expect(failure as? RemoteError == .replacementConflict(target.path, backup.path))
        let pending = try #require(journal.swaps.first)
        let source = try #require(pending.source)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "replacement")
        #expect(source == (kind == .move ? moveSource.path : remote.path(".foldera-BACKUP.part/payload").path))
        #expect((pending.staging == nil) == (kind == .move))

        // Reopening the journal must preserve the source evidence and block mutations until resolved.
        let reopened = SwapJournal(defaults: preferences.defaults)
        #expect(reopened.swaps == [pending])
        let restored = RemoteConnections(connector: { _ in server.reconnect() }, journal: reopened)
        var mutations = 0
        await #expect(throws: RemoteError.replacementConflict(target.path, backup.path)) {
            try await restored.perform(endpoint) { _ in mutations += 1 }
        }
        #expect(mutations == 0 && reopened.swaps == [pending])
        #expect(try String(contentsOf: backup, encoding: .utf8) == "original")
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "replacement")
        #expect(try String(contentsOf: target, encoding: .utf8) == "other client's data")

        // Once the other client removes its destination, recovery restores the original safely.
        try FileManager.default.removeItem(at: target)
        _ = try await restored.fileSystem(for: endpoint)
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(try String(contentsOf: moveSource, encoding: .utf8) == "replacement")
        #expect(!FileOperations.exists(backup.deletingLastPathComponent()))
        if let directory = pending.stagingDirectory { #expect(!FileOperations.exists(URL(fileURLWithPath: directory))) }
        #expect(SwapJournal(defaults: preferences.defaults).swaps.isEmpty)
    }

    /// A dropped connection may lose a rename's reply after the server carried it out. Foldera reconnects,
    /// looks, and either finishes the replace or puts the original back.
    @Test func replacingRecoversFromDroppedConnections() async throws {
        let endpoint = uniqueEndpoint(), local = try TestDirectory(), remote = try TestDirectory()
        let errors = ErrorCollector()
        let server = FakeRemoteFileSystem()
        let connections = RemoteConnections { _ in server.reconnect() }
        connections.install(server, for: endpoint)
        var transfers = transfers(choice: .alertFirstButtonReturn)
        transfers.connections = connections
        let folder = endpoint.url(path: remote.url.path)
        let target = remote.path("data.txt")
        func contents() throws -> String { try String(contentsOf: target, encoding: .utf8) }
        func leftovers() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: remote.url.path).sorted() }
        try remote.file("data.txt", contents: "original")

        // The final rename never happens: the original is restored over a new connection.
        let file = try local.file("data.txt", contents: "new")
        server.simulateConnectionDrop("rename", afterCalls: 1, applied: false)
        let failed = await transfers.run(.copy, [file], into: folder)
        #expect(failed.error != nil && errors.errors.count == 1)
        #expect(try contents() == "original")
        #expect(try leftovers() == ["data.txt"])

        // The final rename happens but its reply is lost: the replace is finished, not reported as failed.
        server.simulateConnectionDrop("rename", afterCalls: 1, applied: true)
        let lost = await transfers.run(.copy, [file], into: folder)
        #expect(lost.error == nil && errors.errors.count == 1)
        #expect(try contents() == "new")
        #expect(try leftovers() == ["data.txt"])

        // A move whose reply is lost still counts as moved, so Cut → Paste forgets the source.
        let source = try remote.file("other/data.txt", contents: "moved")
        server.simulateConnectionDrop("rename", afterCalls: 1, applied: true)
        let moved = await transfers.run(.move, [endpoint.url(path: source.path)], into: folder)
        #expect(moved.error == nil && moved.completedSources == [endpoint.url(path: source.path)])
        #expect(try contents() == "moved")
        #expect(try leftovers() == ["data.txt", "other"])

        // Edits: the backup's deletion is lost, so it's settled on the next connection.
        let edit = try local.file("edit.txt", contents: "edited")
        server.simulateConnectionDrop("removeFile", applied: false)
        try await connections.upload(edit, replacing: target.path, on: endpoint) { _ in }
        #expect(try contents() == "edited")
        #expect(connections.journal.swaps.count == 1)
        let pending = try #require(connections.journal.swaps.first)
        #expect(try String(contentsOfFile: pending.backup, encoding: .utf8) == "moved", "the complete backup is still there")
        _ = try await connections.fileSystem(for: endpoint)
        #expect(connections.journal.swaps.isEmpty)
        #expect(try leftovers() == ["data.txt", "other"])

        // When the server can't be reached again at all, the swap waits in the journal and the
        // original comes back once it can.
        let unreachable = RemoteConnections { _ in throw RemoteError.notConnected(endpoint.displayName) }
        unreachable.install(server, for: endpoint)
        server.simulateConnectionDrop("rename", afterCalls: 1, applied: false)
        await #expect(throws: RemoteError.self) { try await unreachable.upload(edit, replacing: target.path, on: endpoint) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: target.path) && unreachable.journal.swaps.count == 1)
        unreachable.install(server.reconnect(), for: endpoint)
        _ = try await unreachable.fileSystem(for: endpoint)
        #expect(try contents() == "edited")
        #expect(try leftovers() == ["data.txt", "other"])
        #expect(unreachable.journal.swaps.isEmpty)
    }

    @Test func swapJournalPersistsAcrossLaunches() throws {
        let preferences = try TestPreferences()
        let swap = PendingSwap(endpoint: uniqueEndpoint(), path: "/a", backup: "/.a.old", staging: nil)
        SwapJournal(defaults: preferences.defaults).add(swap)
        let reopened = SwapJournal(defaults: preferences.defaults)
        #expect(reopened.swaps == [swap])
        reopened.remove(swap)
        #expect(SwapJournal(defaults: preferences.defaults).swaps.isEmpty)
    }

    @Test func quittingWithPendingEditsAsksFirst() async throws {
        let delegate = FolderaAppDelegate()
        #expect(RemoteEditing.shared.pendingFiles.isEmpty)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)

        // A saved copy the server won't take: uploading is tried once more, then the user is asked.
        let endpoint = uniqueEndpoint(), remote = try TestDirectory(), cache = try TestDirectory()
        let errors = ErrorCollector()
        let server = installFakeServer(endpoint)
        let file = try remote.file("page.html", contents: "v1")
        let editing = RemoteEditing(folder: cache.url, openFile: { _ in }, retryDelay: 60)
        let local = try await editing.open(endpoint.url(path: file.path))
        try "v2".write(to: local, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: local.path)
        delegate.editing = editing
        var asked: [[String]] = [], replies: [Bool] = []
        delegate.confirm = { asked.append($0); return false }
        delegate.reply = { replies.append($0) }
        server.fail("upload", with: RemoteError.failed("down"))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await eventually { replies == [false] }
        #expect(asked == [["page.html"]] && errors.errors.count == 1)

        // Once the upload goes through, quitting goes ahead without asking.
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await eventually { replies == [false, true] }
        #expect(asked.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "v2")
        try FileManager.default.removeItem(at: local)
        await editing.uploadChanges()
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
