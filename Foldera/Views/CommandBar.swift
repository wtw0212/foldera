import SwiftUI

/// Windows 11 command bar: New, clipboard actions, Rename, Share, Delete, Sort, View and "See more".
struct CommandBar: View {
    let model: ExplorerWindowModel
    let tab: BrowserTab
    @State private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 2) {
            MenuButton(help: L10n.text("Create a new item in the current location")) {
                let menu = NSMenu()
                menu.add(L10n.text("Folder"), symbol: "folder") { tab.newFolder() }
                menu.addSeparator()
                menu.add(L10n.text("Text Document"), symbol: "doc.text") { tab.newTextDocument() }
                return menu
            } label: {
                labeled(L10n.text("New"), symbol: "add_circle_filled", tint: Theme.accent.swiftUI, dropdown: true)
            }
            .disabled(tab.isThisMac)

            VerticalSeparator()

            IconButton(symbol: "cut_regular", help: L10n.text("Cut (⌘X)")) { tab.cutSelection() }
                .disabled(!tab.hasSelection)
            IconButton(symbol: "copy_regular", help: L10n.text("Copy (⌘C)")) { tab.copySelection() }
                .disabled(!tab.hasSelection)
            IconButton(symbol: "clipboard_paste_regular", help: L10n.text("Paste (⌘V)")) { tab.paste() }
            IconButton(symbol: "rename_regular", help: tab.selection.count > 1 ? L10n.format("rename.items.help", tab.selection.count) : L10n.text("Rename (F2)")) {
                tab.beginRename()
            }
            .disabled(!tab.hasSelection)
            ShareButton(urls: tab.selectedItems.map(\.url))
                .disabled(!tab.hasSelection)
            IconButton(symbol: "delete_regular", help: L10n.text("Delete (⌘⌫)")) { tab.trashSelection() }
                .disabled(!tab.hasSelection)

            if model.isDualPane {
                VerticalSeparator()
                IconButton(symbol: "arrow.right.doc.on.clipboard", help: L10n.text("Copy to other pane (F5)")) {
                    model.transferToOtherPane(.copy)
                }
                .disabled(!tab.hasSelection)
                IconButton(symbol: "arrow.right.square", help: L10n.text("Move to other pane (F6)")) {
                    model.transferToOtherPane(.move)
                }
                .disabled(!tab.hasSelection)
            }

            VerticalSeparator()

            MenuButton(help: L10n.text("Sort items")) {
                sortMenu()
            } label: {
                labeled(L10n.text("Sort"), symbol: "arrow_sort_regular", dropdown: true)
            }
            MenuButton(help: L10n.text("Layout and view options")) {
                viewMenu()
            } label: {
                labeled(L10n.text("View"), symbol: tab.viewMode.symbol, dropdown: true)
            }

            VerticalSeparator()

            MenuButton(help: L10n.text("See more")) {
                moreMenu()
            } label: {
                AppIcon(name: "more_horizontal_regular")
                    .frame(width: 18, height: 18)
            }

            Spacer()

            // Explorer keeps the Details pane toggle at the right end of the command bar.
            Button {
                settings.toggle(.details)
            } label: {
                labeled(L10n.text("Details"), symbol: "panel_right_regular")
            }
            .buttonStyle(SubtleButtonStyle())
            .background(RoundedRectangle(cornerRadius: 4).fill(settings.sidePane == .details ? Theme.selection.swiftUI : .clear))
            .help(L10n.text("Details pane with preview (⌥⌘P)"))
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    private func labeled(_ title: String, symbol: String, tint: Color? = nil, dropdown: Bool = false) -> some View {
        HStack(spacing: 6) {
            AppIcon(name: symbol)
                .foregroundStyle(tint ?? Theme.text.swiftUI)
            Text(title)
            if dropdown {
                AppIcon(name: "chevron_down_regular", size: 10)
                    .foregroundStyle(Theme.secondaryText.swiftUI)
            }
        }
        .frame(height: 18)
    }

    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for field in SortField.allCases {
            menu.add(field.title, checked: tab.sort.field == field) {
                tab.sort.field = field
            }
        }
        menu.addSeparator()
        menu.add(L10n.text("Ascending"), checked: tab.sort.ascending) { tab.sort.ascending = true }
        menu.add(L10n.text("Descending"), checked: !tab.sort.ascending) { tab.sort.ascending = false }
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in ViewMode.allCases {
            let item = menu.add(mode.title, symbol: mode.symbol, checked: tab.viewMode == mode) { tab.viewMode = mode }
            item.keyEquivalent = String(mode.shortcutNumber)
            item.keyEquivalentModifierMask = [.command, .option]
        }
        menu.addSeparator()
        menu.add(L10n.text("Compact view"), symbol: "arrow.down.right.and.arrow.up.left", checked: settings.compactView) {
            settings.compactView.toggle()
        }
        let show = NSMenuItem(title: L10n.text("Show"), action: nil, keyEquivalent: "")
        show.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        let showMenu = NSMenu()
        showMenu.add(L10n.text("Navigation pane"), checked: settings.showNavigationPane) { settings.showNavigationPane.toggle() }
        showMenu.add(L10n.text("Details pane"), checked: settings.sidePane == .details) { settings.toggle(.details) }
        showMenu.add(L10n.text("Dual pane"), checked: model.isDualPane) { model.toggleDualPane() }
        showMenu.addSeparator()
        showMenu.add(L10n.text("File name extensions"), checked: settings.showExtensions) { settings.showExtensions.toggle() }
        showMenu.add(L10n.text("Hidden items"), checked: settings.showHiddenFiles) { settings.showHiddenFiles.toggle() }
        show.submenu = showMenu
        menu.addItem(show)
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.add(L10n.text("Select all"), symbol: "checkmark.rectangle.stack") { tab.selectAll() }
        menu.add(L10n.text("Select none"), symbol: "rectangle.stack") { tab.selectNone() }
        menu.add(L10n.text("Invert selection"), symbol: "arrow.left.arrow.right") { tab.invertSelection() }
        menu.addSeparator()
        menu.add(L10n.text("Copy path"), symbol: "link") { tab.copyPathOfSelection() }
        menu.add(L10n.text("Show in Finder"), symbol: "macwindow") { tab.showInFinder() }
        menu.add(L10n.text("Open in Terminal"), symbol: "terminal") { tab.openInTerminal() }
        menu.addSeparator()
        menu.add(L10n.text("Properties"), symbol: "info.circle") { tab.showProperties() }
        return menu
    }
}

private struct ShareButton: View {
    let urls: [URL]
    @State private var frame: CGRect = .zero

    var body: some View {
        IconButton(symbol: "share_regular", help: L10n.text("Share")) {
            guard let view = NSApp.keyWindow?.contentView else { return }
            let rect = view.isFlipped ? frame : NSRect(
                x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height
            )
            NSSharingServicePicker(items: urls).show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}
