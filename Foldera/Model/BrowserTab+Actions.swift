import AppKit
import Carbon

/// Commands shared by the command bar, context menu, keyboard shortcuts and the menu bar.
extension BrowserTab {
    var clipboard: FileClipboard { .shared }
    var recents: RecentItems { settings.recents }

    var hasSelection: Bool { !selection.isEmpty }
    var canPaste: Bool { acceptsItems && clipboard.canPaste }

    /// Opens an item: folders navigate in place, everything else opens with its default app.
    func open(_ item: FileItem) {
        if item.isNavigable {
            navigate(to: item.url)
        } else {
            openFile(item.url)
        }
    }

    /// Opens a recent item: folders here, files in their app.
    func openRecent(_ item: RecentItem) {
        if item.isFolder {
            navigate(to: item.url)
        } else {
            openFile(item.url)
        }
    }

    /// Opens a file in its app; server files open from a temporary copy that uploads when saved.
    /// Archives open as folders, like Explorer's built-in zip support (Archive Utility can't open encrypted
    /// 7z, rar and several other formats); tar.gz and the like, which can't be browsed, are extracted instead.
    private func openFile(_ url: URL) {
        recents.record(url, isFolder: false)
        if isRecent { reload() }
        if url.isRemote {
            remoteOpen(url)
        } else if url.isInArchive {
            openArchiveItem(url)
        } else if Archives.isBrowsable(url) {
            openArchiveWindow(url)
        } else if Archives.isArchive(url) {
            extract([url], .ownFolder)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openSelection() {
        let items = selectedItems
        if items.count == 1, let item = items.first {
            open(item)
            return
        }
        // Several items: open files with their apps, and the first folder in this tab.
        for item in items where !item.isNavigable {
            openFile(item.url)
        }
        if let folder = items.first(where: \.isNavigable) {
            navigate(to: folder.url)
        }
    }

    func newFolder() {
        if isRemote { return remoteNewItem(named: "New folder", folder: true) }
        perform { url in
            let created = try FileOperations.newFolder(in: url)
            FileUndo.shared.record(.created([created]), name: "New Folder")
            self.beginRename(created)
        }
    }

    func newTextDocument() {
        if isRemote { return remoteNewItem(named: "New Text Document.txt", folder: false) }
        perform { url in
            let created = try FileOperations.newTextDocument(in: url)
            FileUndo.shared.record(.created([created]), name: "New Text Document")
            self.beginRename(created)
        }
    }

    /// Inline rename for one item; the bulk rename sheet when several are selected (like Finder).
    func beginRename(_ url: URL? = nil) {
        guard !isRecent, !isInsideArchive else { return }
        if url == nil, selection.count > 1 {
            bulkRenameItems = selectedItems
            return
        }
        guard let target = (url ?? selectedItems.first?.url)?.normalizedFileURL else { return }
        selection = [target]
        renameRequest = RenameRequest(url: target)
    }

    func commitRename(of url: URL, to newName: String) {
        renameRequest = nil
        guard newName != url.lastPathComponent else { return }
        if url.isRemote { return remoteRename(url, to: newName) }
        perform { _ in
            let renamed = try FileOperations.rename(url, to: newName)
            FileUndo.shared.record(.renamed(from: url, to: renamed), name: "Rename")
            self.selection = [renamed.normalizedFileURL]
        }
    }

    func cutSelection() {
        guard hasSelection, !isInsideArchive else { return }
        clipboard.cut(selectedItems.map(\.url))
    }

    func copySelection() {
        guard hasSelection else { return }
        if isInsideArchive { return copyArchiveSelection() }
        clipboard.copy(selectedItems.map(\.url))
    }

    func paste(into folder: URL? = nil) {
        let destination = folder ?? url
        Task {
            let result = await clipboard.paste(into: destination)
            if destination == url, !result.results.isEmpty {
                selection = Set(result.results.map(\.normalizedFileURL))
                reload()
            }
        }
    }

    func trashSelection() {
        if isRemote { return remoteDeleteSelection() }
        if isRecent { return removeSelectionFromRecent() }
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        perform { _ in
            do {
                FileUndo.shared.record(.trashed(try FileOperations.trash(urls)), name: "Delete")
            } catch let failure as FileChange.Failure {
                FileUndo.shared.record(failure.remaining, name: "Delete")
                self.reload()
                throw failure
            }
            self.selection = []
        }
    }

    // MARK: Archives

    enum ExtractDestination {
        /// The archive's own folder, or a new folder named after the archive next to it.
        case here, ownFolder
        /// A chosen folder; `ownFolder` puts each archive in a new folder named after it there.
        case folder(URL, ownFolder: Bool)
    }

    var selectedArchives: [URL] { isRemote || isRecent || isInsideArchive ? [] : selectedItems.map(\.url).filter(Archives.isArchive) }

    /// Extracts the selected archives: into this folder, or each into a folder named after it.
    /// Encrypted archives ask for their password (again if it was wrong).
    func extractSelection(_ destination: ExtractDestination) {
        extract(selectedArchives, destination)
    }

    private func extract(_ archives: [URL], _ destination: ExtractDestination) {
        guard !archives.isEmpty else { return }
        Task {
            var created: [URL] = []
            var failure: Error?
            for archive in archives {
                let folder: URL = switch destination {
                case .here, .ownFolder: archive.deletingLastPathComponent()
                case .folder(let folder, _): folder
                }
                do {
                    let total = await ArchiveExtraction.size(of: [], in: archive)
                    // The password is read when each attempt starts: one typed while browsing is tried first.
                    let added = try await ArchiveExtraction.run(archive, itemCount: 1, source: ArchiveLocation(archive: archive).url, into: folder,
                                                                totalBytes: total, action: L10n.text("Extract")) { progress in
                        let password = ArchiveCatalog.shared.password(for: archive)
                        return switch destination {
                        case .here, .folder(_, ownFolder: false):
                            try Archives.extractHere(archive, into: folder, password: password, progress: progress, totalBytes: total)
                        case .ownFolder, .folder(_, ownFolder: true):
                            [try Archives.extractToFolder(archive, in: folder, password: password, progress: progress, totalBytes: total)]
                        }
                    }
                    created += added ?? []
                } catch {
                    failure = failure ?? Archives.Failure(message: "“\(archive.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            // Only an Extract to a chosen folder opens it; the others may finish after the user moved on.
            if case .folder = destination {
                finishArchiveJob(name: "Extract", created: created, error: failure, revealing: true)
            } else {
                finishArchiveJob(name: "Extract", created: created, error: failure)
            }
        }
    }

    /// The command bar's Extract: asks where to put the selected archives, starting in their folder,
    /// and by default gives each a new folder named after it.
    func extractSelectionChoosingDestination() {
        extractChoosingDestination(selectedArchives)
    }

    func extractChoosingDestination(_ archives: [URL]) {
        guard let first = archives.first else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Extract")
        panel.message = archives.count == 1
            ? L10n.format("Choose where to extract “%@”.", first.lastPathComponent)
            : L10n.format("Choose where to extract %lld archives.", archives.count)
        panel.prompt = L10n.text("Extract")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = first.deletingLastPathComponent()
        let ownFolder = NSButton(checkboxWithTitle: archives.count == 1
            ? L10n.format("Extract into a new folder “%@”", Archives.baseName(of: first))
            : L10n.text("Extract each into a new folder named after it"), target: nil, action: nil)
        ownFolder.state = .on
        panel.accessoryView = ownFolder
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        extract(archives, .folder(folder, ownFolder: ownFolder.state == .on))
    }

    var canCompressSelection: Bool { hasSelection && !isRemote && !isRecent && !isInsideArchive }

    /// Finder-style Compress: "<name>.zip" (or .7z) for one item, "Archive.zip" for several.
    func compressSelection(_ format: Archives.Format = .zip) {
        let items = selectedItems.map(\.url)
        let fallback = url
        guard canCompressSelection,
              let folder = Archives.archiveURL(for: items, format: format, fallbackFolder: fallback)?.deletingLastPathComponent() else { return }
        compress(items, into: folder) { progress in
            try Archives.compress(items, format: format, fallbackFolder: fallback, progress: progress)
        }
    }

    /// "Compress to…": asks for the archive's name, place, format, level and password.
    func compressSelectionWithOptions() {
        guard canCompressSelection else { return }
        compressItems = selectedItems.map(\.url)
    }

    /// Compresses `items` into "<name>.<ext>" in `folder`, keeping both if that name is taken.
    func compress(_ items: [URL], options: Archives.Options, named name: String, in folder: URL) {
        guard !items.isEmpty else { return }
        compress(items, into: folder) { progress in
            try Archives.compress(items, options: options, named: name, in: folder, progress: progress)
        }
    }

    /// Runs a compression as a tracked transfer. `body` returns the published archive.
    private func compress(_ items: [URL], into folder: URL, body: @escaping @Sendable (TransferProgress) throws -> URL) {
        let transfer = FileTransfer(kind: .compress, itemCount: items.count, source: items[0].deletingLastPathComponent(), destination: folder)
        Task {
            do {
                let total = await Task.detached { items.reduce(0) { $0 + CopyEngine.size(of: $1) } }.value
                let archive = try await FileTransfers.shared.track(transfer, totalBytes: total, body)
                finishArchiveJob(name: "Compress", created: [archive], error: nil)
            } catch is CopyEngine.Cancelled {
                finishArchiveJob(name: "Compress", created: [], error: nil)
            } catch let failure as FileChange.Failure {
                finishArchiveJob(name: "Compress", created: failure.remaining.createdURLs.filter(FileOperations.exists), error: failure)
            } catch {
                finishArchiveJob(name: "Compress", created: [], error: error)
            }
        }
    }

    /// Records undo and selects what was created.
    func finishArchiveJob(name: String, created: [URL], error: Error?, revealing: Bool = false) {
        if !created.isEmpty {
            FileUndo.shared.record(.created(created), name: name)
            let selected = Set(created.map(\.normalizedFileURL))
            let folders = Set(created.map { $0.deletingLastPathComponent().normalizedFileURL })
            if revealing, folders.count == 1, let folder = folders.first, folder != url {
                // Extracted somewhere else: go there, like Explorer's "Show extracted files".
                navigate(to: folder, selecting: selected)
            } else {
                selection = selected
                reload()
            }
        }
        if let error { Self.present(error) }
    }

    /// Asks for an archive's password; `action` names the button. Nil when cancelled.
    static func askPassword(for archive: URL, wasWrong: Bool, action: String) -> String? {
        if let passwordPrompt { return passwordPrompt(archive, wasWrong) }
        let alert = NSAlert()
        alert.messageText = L10n.format("Enter the password for “%@”", archive.lastPathComponent)
        alert.informativeText = wasWrong ? L10n.text("The password is incorrect. Try again.") : L10n.text("This archive is protected with a password.")
        alert.alertStyle = wasWrong ? .warning : .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func copyPathOfSelection() {
        let paths = (hasSelection ? selectedItems.map(\.url) : [url]).map { $0.archiveLocation?.displayPath ?? $0.path }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func showInFinder() {
        if let location = url.archiveLocation { return NSWorkspace.shared.activateFileViewerSelecting([location.archive]) }
        guard !isRemote, !isPage, hasSelection || !isRecent else { return }
        if hasSelection {
            NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url).filter(\.isFileURL))
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openInTerminal() {
        if isRemote { return remoteOpenInTerminal() }
        guard acceptsItems, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens the Finder "Get Info" window, the closest macOS equivalent of Explorer's Properties.
    func showProperties() {
        if isRemote { return remoteShowProperties() }
        if isInsideArchive { return archiveShowProperties() }
        guard !isPage, hasSelection || !isRecent else { return }
        let targets = (hasSelection ? selectedItems.map(\.url) : [url]).filter(\.isFileURL)
        guard !targets.isEmpty else { return }
        do {
            // One event per item: Finder answers a list of windows with success but opens none of them.
            for target in targets {
                let reply = try Self.propertiesEvent(for: target).sendEvent(options: .defaultOptions, timeout: TimeInterval(kAEDefaultTimeout))
                if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(code))
                }
            }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        } catch {
            Self.present(error)
        }
    }

    // MARK: Recent

    /// On the Recent page, Delete forgets items instead of deleting them.
    func removeSelectionFromRecent() {
        for item in selectedItems { recents.remove(item.url) }
        selection = []
        reload()
    }

    /// Opens the folder that contains the selected item, with the item selected.
    func openItemLocation() {
        guard let item = selectedItems.first else { return }
        let folder = item.url.isRemote ? RemoteTransfers.parent(of: item.url) : item.url.deletingLastPathComponent().normalizedFileURL
        navigate(to: folder)
        selection = [item.url]
    }

    /// Bigger or smaller layout (⌘+ / ⌘−, ⌘-scroll, pinch).
    func zoom(in zoomIn: Bool) {
        guard !isPage else { return }
        viewMode = viewMode.zoomed(in: zoomIn)
        // Switching between the list and icon views replaces the view; keep keyboard focus for the next ⌘+.
        requestListFocus()
    }

    func selectAll() { selection = Set(visibleItems.map(\.url)) }
    func selectNone() { selection = [] }
    func invertSelection() { selection = Set(visibleItems.map(\.url)).subtracting(selection) }

    func setSort(_ field: SortField) {
        if sort.field == field {
            sort.ascending.toggle()
        } else {
            sort = SortOrder(field: field, ascending: field == .name || field == .kind)
        }
    }

    // MARK: Helpers

    private func perform(_ body: (URL) throws -> Void) {
        guard acceptsItems else { return }
        do {
            try body(url)
            reload()
        } catch {
            Self.present(error)
        }
    }

    /// Replaces the error alert (tests).
    static var errorPresenter: ((Error) -> Void)?
    /// Replaces the archive password prompt (tests): archive and whether the last password was wrong.
    static var passwordPrompt: ((URL, Bool) -> String?)?

    static func present(_ error: Error) {
        if let errorPresenter { return errorPresenter(error) }
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Finder's Open event for `url`'s information window: what `open information window of (… as alias)` sends,
    /// with the file as file-URL data. No filename is interpreted as code.
    static func propertiesEvent(for url: URL) throws -> NSAppleEventDescriptor {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        func specifier(_ want: OSType, _ form: OSType, _ data: NSAppleEventDescriptor, in container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
            record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
            record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
            record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
            guard let specifier = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw CocoaError(.coderInvalidValue) }
            return specifier
        }
        // alias (by name) → its information window property ('iwnd' in Finder's dictionary).
        let file = try specifier(OSType(typeAlias), OSType(formName), NSAppleEventDescriptor(fileURL: url), in: .null())
        let window = try specifier(OSType(cProperty), OSType(formPropertyID), NSAppleEventDescriptor(typeCode: 0x69776E64), in: file)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(window, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
}
