import AppKit

/// Commands shared by the command bar, context menu, keyboard shortcuts and the menu bar.
extension BrowserTab {
    private var clipboard: FileClipboard { .shared }

    var hasSelection: Bool { !selection.isEmpty }
    var canPaste: Bool { !isThisMac && clipboard.canPaste }

    /// Opens an item: folders navigate in place, everything else opens with its default app.
    func open(_ item: FileItem) {
        if item.isNavigable {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
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
            NSWorkspace.shared.open(item.url)
        }
        if let folder = items.first(where: \.isNavigable) {
            navigate(to: folder.url)
        }
    }

    func newFolder() {
        perform { url in
            let created = try FileOperations.newFolder(in: url)
            FileUndo.shared.record(.created([created]), name: "New Folder")
            self.beginRename(created)
        }
    }

    func newTextDocument() {
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
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        perform { _ in
            FileUndo.shared.record(.trashed(try FileOperations.trash(urls)), name: "Delete")
            self.selection = []
        }
    }

    func copyPathOfSelection() {
        let paths = (hasSelection ? selectedItems.map(\.url) : [url]).map(\.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func showInFinder() {
        if hasSelection {
            NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openInTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens the Finder "Get Info" window, the closest macOS equivalent of Explorer's Properties.
    func showProperties() {
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
        guard !isThisMac else { return }
        do {
            try body(url)
            reload()
        } catch {
            Self.present(error)
        }
    }

    static func present(_ error: Error) {
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
