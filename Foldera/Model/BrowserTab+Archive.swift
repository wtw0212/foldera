import AppKit

/// Opens archives in windows of their own (see `FolderaApp`).
enum ArchiveWindows {
    static let id = "archive"
    /// Set by each explorer window to its `openWindow` action; nil in tests, where archives open in the same tab.
    static var opener: ((URL) -> Void)?
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
        guard let archive = url.archiveLocation?.archive else { return }
        Task {
            do {
                guard let extracted = try await withArchivePassword(archive, action: L10n.text("Open"), {
                    try ArchiveDirectory.extractToTemporaryFolder([url])
                })?.first else { return }
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
        let urls = selectedItems.map(\.url)
        guard let archive = urls.first?.archiveLocation?.archive else { return }
        Task {
            do {
                guard let extracted = try await withArchivePassword(archive, action: L10n.text("Copy"), {
                    try ArchiveDirectory.extractToTemporaryFolder(urls)
                }) else { return }
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
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        extract(chosen, from: location.archive, into: folder)
    }

    /// Extracts items from an archive into `folder`, keeping both when names clash, then shows them there.
    func extract(_ locations: [ArchiveLocation], from archive: URL, into folder: URL) {
        Task {
            do {
                let created = try await withArchivePassword(archive, action: L10n.text("Extract")) {
                    let fm = FileManager.default
                    let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                    defer { try? fm.removeItem(at: staging) }
                    try ArchiveDirectory.extract(locations, from: archive, into: staging)
                    var created: [URL] = []
                    for location in locations {
                        let destination = FileOperations.uniqueURL(named: location.name, in: folder)
                        try fm.moveItem(at: staging.appendingPathComponent(location.path), to: destination)
                        created.append(destination)
                    }
                    return created
                }
                finishArchiveJob(name: "Extract", created: created ?? [], error: nil, revealing: true)
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
