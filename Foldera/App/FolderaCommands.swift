import SwiftUI

/// Menu bar commands. Mac shortcuts (⌘) throughout; Cut/Copy/Paste/Delete go through the responder chain
/// so they keep working on text when a text field is focused.
struct FolderaCommands: Commands {
    @FocusedValue(\.explorer) private var explorer
    @State private var settings = AppSettings.shared
    @State private var undo = FileUndo.shared

    private var tab: BrowserTab? { explorer?.activeTab }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { explorer?.newTab() }
                .keyboardShortcut("t")
            Button("Duplicate Tab") { explorer?.duplicateActiveTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("New Folder") { tab?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Text Document") { tab?.newTextDocument() }
            Divider()
            Button("Open") { tab?.openSelection() }
                .keyboardShortcut(.downArrow)
                .disabled(tab?.hasSelection != true)
            Button((tab?.selection.count ?? 0) > 1 ? "Rename \(tab?.selection.count ?? 0) Items…" : "Rename") { tab?.beginRename() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
                .disabled(tab?.hasSelection != true)
            Button("Properties") { tab?.showProperties() }
                .keyboardShortcut("i")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { explorer?.closeActiveTabOrWindow() }
                .keyboardShortcut("w")
        }

        // File undo works whenever the window is active; a focused text field keeps its own text undo.
        CommandGroup(replacing: .undoRedo) {
            Button(undo.undoTitle) {
                if let text = Self.textUndoManager, text.canUndo { text.undo() } else { undo.undo() }
            }
            .keyboardShortcut("z")
            .disabled(!undo.canUndo && Self.textUndoManager?.canUndo != true)
            Button(undo.redoTitle) {
                if let text = Self.textUndoManager, text.canRedo { text.redo() } else { undo.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!undo.canRedo && Self.textUndoManager?.canRedo != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Path") { tab?.copyPathOfSelection() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Invert Selection") { tab?.invertSelection() }
        }

        CommandMenu("Go") {
            Button("Back") { tab?.goBack() }
                .keyboardShortcut("[")
                .disabled(tab?.canGoBack != true)
            Button("Forward") { tab?.goForward() }
                .keyboardShortcut("]")
                .disabled(tab?.canGoForward != true)
            Button("Enclosing Folder") { tab?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(tab?.canGoUp != true)
            Divider()
            go("Home", StandardLocations.home.url, key: "h")
            ForEach(StandardLocations.pinned) { location in
                Button(location.title) { open(location.url) }
            }
            Divider()
            Button("Go to Folder…") { explorer?.isEditingAddress = true }
                .keyboardShortcut("l")
            Button("Search") { explorer?.focusSearch() }
                .keyboardShortcut("f")
        }

        CommandGroup(before: .toolbar) {
            Button("Refresh") { tab?.reload() }
                .keyboardShortcut("r")
            Divider()
            Toggle("Navigation Pane", isOn: $settings.showNavigationPane)
            Button(settings.sidePane == .details ? "Hide Details Pane" : "Show Details Pane") { settings.toggle(.details) }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle("File Name Extensions", isOn: $settings.showExtensions)
            Toggle("Hidden Items", isOn: $settings.showHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Compact View", isOn: $settings.compactView)
            Divider()
            ForEach(ViewMode.allCases) { mode in
                Button(mode.title) { tab?.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character(String(mode.shortcutNumber))), modifiers: [.command, .option])
            }
            Divider()
            Picker("Sort By", selection: sortField) {
                ForEach(SortField.allCases) { Text($0.title).tag($0) }
            }
            Divider()
        }

        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { explorer?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { explorer?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { explorer?.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Divider()
        }
    }

    /// Undo manager of a text field being edited, if any.
    private static var textUndoManager: UndoManager? {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager
    }

    private var sortField: Binding<SortField> {
        Binding(
            get: { tab?.sort.field ?? .name },
            set: { tab?.sort.field = $0 }
        )
    }

    private func go(_ title: String, _ url: URL, key: KeyEquivalent) -> some View {
        Button(title) { open(url) }
            .keyboardShortcut(key, modifiers: [.command, .shift])
    }

    private func open(_ url: URL) {
        tab?.navigate(to: url)
        tab?.requestListFocus()
    }
}
