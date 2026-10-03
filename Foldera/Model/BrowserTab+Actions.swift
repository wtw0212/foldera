import AppKit

/// Commands shared by the command bar, context menu, keyboard shortcuts and the menu bar.
extension BrowserTab {
    private var clipboard: FileClipboard { .shared }
    var recents: RecentItems { settings.recents }

    var hasSelection: Bool { !selection.isEmpty }
    var canPaste: Bool { !isPage && clipboard.canPaste }

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
    private func openFile(_ url: URL) {
        recents.record(url, isFolder: false)
        if url.isRemote {
            remoteOpen(url)
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
        guard hasSelection else { return }
        clipboard.cut(selectedItems.map(\.url))
    }

    func copySelection() {
        guard hasSelection else { return }
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

    enum ExtractDestination { case here, ownFolder }

    var selectedArchives: [URL] { isRemote ? [] : selectedItems.map(\.url).filter(Archives.isArchive) }

    /// Extracts the selected archives: into this folder, or each into a folder named after it.
    /// Encrypted archives ask for their password (again if it was wrong).
    func extractSelection(_ destination: ExtractDestination) {
        let archives = selectedArchives
        guard !archives.isEmpty else { return }
        Task {
            var created: [URL] = []
            var failure: Error?
            for archive in archives {
                var password: String?
                while true {
                    do {
                        created += try await Task.detached(priority: .userInitiated) { [password] in
                            switch destination {
                            case .here: try Archives.extractHere(archive, into: archive.deletingLastPathComponent(), password: password)
                            case .ownFolder: [try Archives.extractToFolder(archive, password: password)]
                            }
                        }.value
                    } catch let needed as Archives.PasswordRequired {
                        password = Self.askPassword(for: archive, wasWrong: needed.wasWrong)
                        if password != nil { continue }
                    } catch {
                        failure = failure ?? Archives.Failure(message: "“\(archive.lastPathComponent)”: \(error.localizedDescription)")
                    }
                    break
                }
            }
            finishArchiveJob(name: "Extract", created: created, error: failure)
        }
    }

    /// Finder-style Compress: "<name>.zip" (or .7z) for one item, "Archive.zip" for several.
    func compressSelection(_ format: Archives.Format = .zip) {
        let items = selectedItems.map(\.url)
        guard !items.isEmpty, !isRemote else { return }
        let folder = url
        Task {
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    try Archives.compress(items, format: format, fallbackFolder: folder)
                }.value
                finishArchiveJob(name: "Compress", created: [archive], error: nil)
            } catch {
                finishArchiveJob(name: "Compress", created: [], error: error)
            }
        }
    }

    /// Records undo and selects what was created.
    private func finishArchiveJob(name: String, created: [URL], error: Error?) {
        if !created.isEmpty {
            FileUndo.shared.record(.created(created), name: name)
            selection = Set(created.map(\.normalizedFileURL))
            reload()
        }
        if let error { Self.present(error) }
    }

    /// Asks for an archive's password. Nil when cancelled.
    private static func askPassword(for archive: URL, wasWrong: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.format("Enter the password for “%@”", archive.lastPathComponent)
        alert.informativeText = wasWrong ? L10n.text("The password is incorrect. Try again.") : L10n.text("This archive is protected with a password.")
        alert.alertStyle = wasWrong ? .warning : .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("Extract"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func copyPathOfSelection() {
        let paths = (hasSelection ? selectedItems.map(\.url) : [url]).map(\.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func showInFinder() {
        guard !isRemote, !isPage else { return }
        if hasSelection {
            NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openInTerminal() {
        if isRemote { return remoteOpenInTerminal() }
        guard !isPage, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens the Finder "Get Info" window, the closest macOS equivalent of Explorer's Properties.
    func showProperties() {
        if isRemote { return remoteShowProperties() }
        let targets = hasSelection ? selectedItems.map(\.url) : [url]
        let list = targets.map { "POSIX file \"\(Self.appleScriptEscaped($0.path))\"" }.joined(separator: ", ")
        let source = """
        tell application "Finder"
            activate
            repeat with f in {\(list)}
                open information window of (f as alias)
            end repeat
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
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
        guard !isPage else { return }
        do {
            try body(url)
            reload()
        } catch {
            Self.present(error)
        }
    }

    /// Replaces the error alert (tests).
    static var errorPresenter: ((Error) -> Void)?

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

    private static func appleScriptEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
