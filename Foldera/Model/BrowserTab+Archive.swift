import AppKit

/// Opens archives in windows of their own (see `FolderaApp`).
enum ArchiveWindows {
    static let id = "archive"
    /// Set by each explorer window to its `openWindow` action; nil in tests, where archives open in the same tab.
    static var opener: ((URL) -> Void)?
}

/// Extractions shown in the progress window (with Cancel), asking for the archive's password while one is needed.
enum ArchiveExtraction {
    /// Runs `body` as a tracked transfer. Nil when the password prompt or Cancel stopped it.
    static func run<T: Sendable>(_ archive: URL, itemCount: Int, source: URL, into destination: URL, totalBytes: Int64,
                                 action: String, _ body: @escaping @Sendable (TransferProgress) throws -> T) async throws -> T? {
        while true {
            let transfer = FileTransfer(kind: .extract, itemCount: itemCount, source: source, destination: destination)
            do {
                return try await FileTransfers.shared.track(transfer, totalBytes: totalBytes, body)
            } catch is CopyEngine.Cancelled {
                return nil
            } catch let needed as Archives.PasswordRequired {
                guard let password = BrowserTab.askPassword(for: archive, wasWrong: needed.wasWrong, action: action) else { return nil }
                ArchiveCatalog.shared.setPassword(password, for: archive)
            }
        }
    }

    /// Bytes to unpack, for the progress bar: from the archive's listing, or its own size when that can't be read.
    static func size(of paths: [String], in archive: URL) async -> Int64 {
        await Task.detached {
            ArchiveCatalog.shared.unpackedSize(of: paths, in: archive)
                ?? Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }.value
    }

    /// Takes items out of one archive into a new temporary folder, to open, copy or preview them.
    static func toTemporaryFolder(_ urls: [URL], action: String) async throws -> [URL]? {
        let locations = urls.compactMap(\.archiveLocation)
        guard let first = locations.first else { return [] }
        let total = await size(of: locations.map(\.path), in: first.archive)
        return try await run(first.archive, itemCount: locations.count, source: first.parent?.url ?? ArchiveLocation(archive: first.archive).url,
                             into: ArchiveDirectory.temporaryRoot, totalBytes: total, action: action) { progress in
            try ArchiveDirectory.extractToTemporaryFolder(urls, progress: progress, totalBytes: total)
        }
    }

    /// Extracts items into `folder`, keeping both when names clash. Returns what was added; nil when stopped.
    static func items(_ locations: [ArchiveLocation], from archive: URL, into folder: URL) async throws -> [URL]? {
        guard let first = locations.first else { return [] }
        let total = await size(of: locations.map(\.path), in: archive)
        return try await run(archive, itemCount: locations.count, source: first.parent?.url ?? ArchiveLocation(archive: archive).url,
                             into: folder, totalBytes: total, action: L10n.text("Extract")) { progress in
            try ArchiveDirectory.extractKeepingBoth(locations, from: archive, into: folder, progress: progress, totalBytes: total)
        }
    }
}

/// Commands for folders inside archives. They're read-only: items come out by opening, copying or extracting them.
extension BrowserTab {
    /// Reads the archive's listing here first, asking for its password if the names are encrypted, so a
    /// wrong password or a broken archive is reported in this window instead of opening an empty one.
    func openArchiveWindow(_ archive: URL) {
        let root = ArchiveLocation(archive: archive)
        Task {
            do {
                guard try await withArchivePassword(archive, action: L10n.text("Open"), {
                    _ = try ArchiveCatalog.shared.children(of: root)
                }) != nil else { return }
                if let opener = ArchiveWindows.opener {
                    opener(root.url)
                } else {
                    navigate(to: root.url)
                }
            } catch {
                Self.present(error)
            }
        }
    }

    /// Opens a file from an archive from a temporary copy; an archive inside the archive opens as a folder.
    func openArchiveItem(_ url: URL) {
        Task {
            do {
                guard let extracted = try await ArchiveExtraction.toTemporaryFolder([url], action: L10n.text("Open"))?.first else { return }
                if Archives.isBrowsable(extracted) {
                    navigate(to: ArchiveLocation(archive: extracted).url)
                } else {
                    NSWorkspace.shared.open(extracted)
                }
            } catch {
                Self.present(error)
            }
        }
    }

    /// Copy inside an archive: the items are extracted to a temporary folder and those copies go on the
    /// clipboard, so they paste anywhere, Finder included.
    func copyArchiveSelection() {
        let urls = selectedItems.map(\.url).filter(\.isInArchive)
        guard !urls.isEmpty else { return }
        Task {
            do {
                guard let extracted = try await ArchiveExtraction.toTemporaryFolder(urls, action: L10n.text("Copy")) else { return }
                clipboard.copy(extracted)
            } catch {
                Self.present(error)
            }
        }
    }

    /// The command bar's Extract inside an archive: the selected items, or everything when nothing is selected,
    /// to a folder the user chooses.
    func extractFromArchiveChoosingDestination() {
        guard let location = url.archiveLocation else { return }
        let chosen = selectedItems.compactMap(\.url.archiveLocation)
        guard !chosen.isEmpty else { return extractChoosingDestination([location.archive]) }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Extract")
        panel.message = chosen.count == 1
            ? L10n.format("Choose where to extract “%@”.", chosen[0].name)
            : L10n.format("Choose where to extract %lld items.", chosen.count)
        panel.prompt = L10n.text("Extract")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = location.archive.deletingLastPathComponent()
        let opens = Self.openWhenDoneCheckbox()
        panel.accessoryView = Self.checkboxStack([opens])
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Self.opensExtractedFolder = opens.state == .on
        extract(chosen, from: location.archive, into: folder, opens: opens.state == .on)
    }

    /// Extracts items from an archive into `folder`, keeping both when names clash; `opens` then shows them there.
    func extract(_ locations: [ArchiveLocation], from archive: URL, into folder: URL, opens: Bool = false) {
        Task {
            do {
                let created = try await ArchiveExtraction.items(locations, from: archive, into: folder) ?? []
                finishArchiveJob(name: "Extract", created: created, error: nil)
                if opens { revealExtracted(created, insideNewFolder: false) }
            } catch {
                finishArchiveJob(name: "Extract", created: [], error: error)
            }
        }
    }

    /// A summary alert: items inside an archive have no Get Info window.
    func archiveShowProperties() {
        guard let location = url.archiveLocation else { return }
        let targets = selectedItems
        let alert = NSAlert()
        if targets.count == 1, let item = targets.first {
            alert.messageText = item.name
            var lines = [L10n.format("Location: %@", location.displayPath), L10n.format("Type: %@", item.localizedKind)]
            if let size = item.size { lines.append(L10n.format("Size: %@", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
            if let date = item.dateModified {
                lines.append(L10n.format("Modified: %@", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))))
            }
            alert.informativeText = lines.joined(separator: "\n")
        } else if targets.isEmpty {
            alert.messageText = title
            alert.informativeText = L10n.format("Location: %@", location.displayPath)
        } else {
            alert.messageText = L10n.format("items.selected", targets.count)
            let bytes = targets.compactMap(\.size).reduce(0, +)
            alert.informativeText = L10n.format("Size: %@", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        alert.runModal()
    }

    /// Runs `body` off the main thread, asking for the archive's password whenever it reports one is needed.
    /// Nil when the prompt is cancelled.
    func withArchivePassword<T: Sendable>(_ archive: URL, action: String, _ body: @escaping @Sendable () throws -> T) async throws -> T? {
        while true {
            do {
                return try await Task.detached(priority: .userInitiated, operation: body).value
            } catch let needed as Archives.PasswordRequired {
                guard let password = Self.askPassword(for: archive, wasWrong: needed.wasWrong, action: action) else { return nil }
                ArchiveCatalog.shared.setPassword(password, for: archive)
            }
        }
    }
}

/// Copies of archive items taken out for thumbnails, the Details pane and Quick Look, kept for the session.
/// Requests that arrive together (a folder's thumbnails) are taken out in one 7-Zip run.
final class ArchivePreviews {
    static let shared = ArchivePreviews()

    /// Larger items get no automatic thumbnail or Details preview: taking them out would take too long.
    static let automaticSizeLimit: Int64 = 64 * 1024 * 1024

    private struct CachedFile {
        let file: URL
        let signature: ArchiveSignature
    }

    private var files: [URL: CachedFile] = [:]
    private var waiting: [URL: [CheckedContinuation<URL?, Never>]] = [:]
    private var queued: [URL: [URL]] = [:]

    func cachedFile(for url: URL) -> URL? {
        guard let cached = files[url], let archive = url.archiveLocation?.archive,
              cached.signature == (try? ArchiveSignature(archive)), FileManager.default.fileExists(atPath: cached.file.path) else {
            files[url] = nil
            return nil
        }
        return cached.file
    }

    /// The item's copy, taken out quietly (no progress, no password prompt). Nil when that isn't possible.
    func file(for url: URL) async -> URL? {
        if let file = cachedFile(for: url) { return file }
        guard let archive = url.archiveLocation?.archive else { return nil }
        return await withCheckedContinuation { continuation in
            waiting[url, default: []].append(continuation)
            guard !(queued[archive]?.contains(url) ?? false) else { return }
            let first = queued[archive] == nil
            queued[archive, default: []].append(url)
            if first {
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    await flush(archive)
                }
            }
        }
    }

    private func flush(_ archive: URL) async {
        let urls = queued.removeValue(forKey: archive) ?? []
        let callbacks = urls.map { waiting.removeValue(forKey: $0) ?? [] }
        let signature = try? ArchiveSignature(archive)
        let extracted = await Task.detached { try? ArchiveDirectory.extractToTemporaryFolder(urls) }.value
        let unchanged = signature != nil && signature == (try? ArchiveSignature(archive))
        for (index, url) in urls.enumerated() {
            let file = unchanged ? extracted?[index] : nil
            if let file, let signature { files[url] = CachedFile(file: file, signature: signature) }
            for continuation in callbacks[index] { continuation.resume(returning: file) }
        }
    }

    /// For Quick Look: takes out whatever isn't ready yet, with progress and the password prompt.
    /// False when that was cancelled or failed.
    func prepare(_ urls: [URL]) async -> Bool {
        let missing = urls.filter { $0.isInArchive && cachedFile(for: $0) == nil }
        guard !missing.isEmpty else { return true }
        do {
            let locations = missing.compactMap(\.archiveLocation)
            guard locations.count == missing.count else { return false }
            let signatures = try locations.map { try ArchiveSignature($0.archive) }
            guard let extracted = try await ArchiveExtraction.toTemporaryFolder(missing, action: L10n.text("Open")) else { return false }
            guard try locations.map({ try ArchiveSignature($0.archive) }) == signatures else { return false }
            for (index, url) in missing.enumerated() { files[url] = CachedFile(file: extracted[index], signature: signatures[index]) }
            return true
        } catch {
            BrowserTab.present(error)
            return false
        }
    }
}
