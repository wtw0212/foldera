import SwiftUI

/// Menu bar commands. Mac shortcuts (⌘) throughout; Cut/Copy/Paste/Delete go through the responder chain
/// so they keep working on text when a text field is focused.
struct FolderaCommands: Commands {
    @FocusedValue(\.explorer) private var explorer
    @State private var settings = AppSettings.shared
    @State private var undo = FileUndo.shared
    @State private var editing = RemoteEditing.shared

    private var tab: BrowserTab? { explorer?.activeTab }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L10n.text("New Tab")) { explorer?.newTab() }
                .keyboardShortcut("t")
            Button(L10n.text("Duplicate Tab")) { explorer?.duplicateActiveTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button(L10n.text("New Folder")) { tab?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L10n.text("New Text Document")) { tab?.newTextDocument() }
            Divider()
            Button(L10n.text("Open")) { tab?.openSelection() }
                .keyboardShortcut(.downArrow)
                .disabled(tab?.hasSelection != true)
            Button((tab?.selection.count ?? 0) > 1 ? L10n.format("rename.items.menu", tab?.selection.count ?? 0) : L10n.text("Rename")) { tab?.beginRename() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
                .disabled(tab?.hasSelection != true)
            Button(L10n.text("Properties")) { tab?.showProperties() }
                .keyboardShortcut("i")
            Divider()
            Button(L10n.text("Copy to Other Pane")) { explorer?.transferToOtherPane(.copy) }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [])
                .disabled(explorer?.otherTab == nil || tab?.hasSelection != true)
            Button(L10n.text("Move to Other Pane")) { explorer?.transferToOtherPane(.move) }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [])
                .disabled(explorer?.otherTab == nil || tab?.hasSelection != true)
        }

        CommandGroup(replacing: .saveItem) {
            Menu(L10n.text("Server Files")) {
                Button(L10n.text("Finish Editing Server Files")) { Task { await editing.finishEditing() } }
                    .disabled(editing.sessions.allSatisfy(\.isRecovered))
                Button(L10n.text("Resume Recovered Edits")) { editing.resumeRecoveredEdits() }
                    .disabled(!editing.hasRecoveredSessions)
                Button(L10n.text("Show Server Files")) { NSWorkspace.shared.open(editing.folder) }
                    .disabled(!FileOperations.exists(editing.folder))
            }
            Divider()
            Button(L10n.text("Close Tab")) { explorer?.closeActiveTabOrWindow() }
                .keyboardShortcut("w")
        }

        // File undo works whenever the window is active; a focused text field keeps its own text undo.
        CommandGroup(replacing: .undoRedo) {
            Button(undo.undoTitle) {
                if let text = Self.textUndoManager, text.canUndo { text.undo() }
                else if let error = undo.undo() { BrowserTab.present(error) }
            }
            .keyboardShortcut("z")
            .disabled(!undo.canUndo && Self.textUndoManager?.canUndo != true)
            Button(undo.redoTitle) {
                if let text = Self.textUndoManager, text.canRedo { text.redo() }
                else if let error = undo.redo() { BrowserTab.present(error) }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!undo.canRedo && Self.textUndoManager?.canRedo != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button(L10n.text("Copy Path")) { tab?.copyPathOfSelection() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button(L10n.text("Invert Selection")) { tab?.invertSelection() }
        }

        CommandMenu(L10n.text("Go")) {
            Button(L10n.text("Back")) { tab?.goBack() }
                .keyboardShortcut("[")
                .disabled(tab?.canGoBack != true)
            Button(L10n.text("Forward")) { tab?.goForward() }
                .keyboardShortcut("]")
                .disabled(tab?.canGoForward != true)
            Button(L10n.text("Enclosing Folder")) { tab?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(tab?.canGoUp != true)
            Divider()
            go(L10n.text("This Mac"), BrowserTab.thisMacURL, key: "c")
            go(L10n.text("Network"), BrowserTab.networkURL, key: "k")
            go(L10n.text("Recent"), BrowserTab.recentURL, key: "f")
            go(L10n.text("Home"), StandardLocations.home.url, key: "h")
            ForEach(StandardLocations.pinned) { location in
                Button(location.title) { open(location.url) }
            }
            Divider()
            Button(L10n.text("Go to Folder…")) { explorer?.isEditingAddress = true }
                .keyboardShortcut("l")
            Button(L10n.text("Connect to Server…")) { explorer?.networkSheet = .connect("") }
                .keyboardShortcut("k")
            Button(L10n.text("Search")) { explorer?.focusSearch() }
                .keyboardShortcut("f")
        }

        CommandGroup(before: .toolbar) {
            Button(L10n.text("Refresh")) { tab?.reload() }
                .keyboardShortcut("r")
            Divider()
            Toggle(L10n.text("Navigation Pane"), isOn: $settings.showNavigationPane)
            Button(explorer?.isDualPane == true ? L10n.text("Single Pane") : L10n.text("Dual Pane")) { explorer?.toggleDualPane() }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button(settings.sidePane == .details ? L10n.text("Hide Details Pane") : L10n.text("Show Details Pane")) { settings.toggle(.details) }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle(L10n.text("File Name Extensions"), isOn: $settings.showExtensions)
            Toggle(L10n.text("Hidden Items"), isOn: $settings.showHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle(L10n.text("Compact View"), isOn: $settings.compactView)
            Divider()
            Button(L10n.text("Zoom In")) { tab?.zoom(in: true) }
                .keyboardShortcut("+")
                .disabled(tab == nil || tab?.isPage == true || tab?.viewMode == ViewMode.zoomOrder.last)
            Button(L10n.text("Zoom Out")) { tab?.zoom(in: false) }
                .keyboardShortcut("-")
                .disabled(tab == nil || tab?.isPage == true || tab?.viewMode == ViewMode.zoomOrder.first)
            ForEach(ViewMode.allCases) { mode in
                Button(mode.title) { tab?.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character(String(mode.shortcutNumber))), modifiers: [.command, .option])
            }
            Divider()
            Picker(L10n.text("Sort By"), selection: sortField) {
                ForEach(SortField.allCases) { Text($0.title).tag($0) }
            }
            Divider()
        }

        CommandGroup(before: .help) {
            Button(L10n.text("Welcome to Foldera")) { explorer?.isShowingWelcome = true }
                .disabled(explorer == nil)
            Divider()
        }

        CommandGroup(before: .windowList) {
            Button(L10n.text("Show Next Tab")) { explorer?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button(L10n.text("Show Previous Tab")) { explorer?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { number in
                Button(L10n.format("Tab %lld", number)) { explorer?.selectTab(number: number) }
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
