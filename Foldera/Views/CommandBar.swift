import SwiftUI

/// Windows 11 command bar: New, clipboard actions, Rename, Share, Delete, Sort, View and "See more".
struct CommandBar: View {
    let tab: BrowserTab
    @State private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 2) {
            MenuButton(help: "Create a new item in the current location") {
                let menu = NSMenu()
                menu.add("Folder", symbol: "folder") { tab.newFolder() }
                menu.addSeparator()
                menu.add("Text Document", symbol: "doc.text") { tab.newTextDocument() }
                return menu
            } label: {
                labeled("New", symbol: "plus.circle.fill", tint: Theme.accent.swiftUI, dropdown: true)
            }

            VerticalSeparator()

            IconButton(symbol: "scissors", help: "Cut (⌘X)") { tab.cutSelection() }
                .disabled(!tab.hasSelection)
            IconButton(symbol: "doc.on.doc", help: "Copy (⌘C)") { tab.copySelection() }
                .disabled(!tab.hasSelection)
            IconButton(symbol: "doc.on.clipboard", help: "Paste (⌘V)") { tab.paste() }
            IconButton(symbol: "character.cursor.ibeam", help: "Rename (F2)") { tab.beginRename() }
                .disabled(tab.selection.count != 1)
            ShareButton(urls: tab.selectedItems.map(\.url))
                .disabled(!tab.hasSelection)
            IconButton(symbol: "trash", help: "Delete (⌘⌫)") { tab.trashSelection() }
                .disabled(!tab.hasSelection)

            VerticalSeparator()

            MenuButton(help: "Sort items") {
                sortMenu()
            } label: {
                labeled("Sort", symbol: "arrow.up.arrow.down", dropdown: true)
            }
            MenuButton(help: "Layout and view options") {
                viewMenu()
            } label: {
                labeled("View", symbol: "rectangle.grid.1x2", dropdown: true)
            }

            VerticalSeparator()

            MenuButton(help: "See more") {
                moreMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .frame(width: 18, height: 18)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    private func labeled(_ title: String, symbol: String, tint: Color? = nil, dropdown: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint ?? Theme.text.swiftUI)
            Text(title)
            if dropdown {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
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
        menu.add("Ascending", checked: tab.sort.ascending) { tab.sort.ascending = true }
        menu.add("Descending", checked: !tab.sort.ascending) { tab.sort.ascending = false }
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.add("Details", symbol: "list.bullet", checked: true) {}
        menu.addSeparator()
        menu.add("Compact view", symbol: "arrow.down.right.and.arrow.up.left", checked: settings.compactView) {
            settings.compactView.toggle()
        }
        let show = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        show.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        let showMenu = NSMenu()
        showMenu.add("Navigation pane", checked: settings.showNavigationPane) { settings.showNavigationPane.toggle() }
        showMenu.add("File name extensions", checked: settings.showExtensions) { settings.showExtensions.toggle() }
        showMenu.add("Hidden items", checked: settings.showHiddenFiles) { settings.showHiddenFiles.toggle() }
        show.submenu = showMenu
        menu.addItem(show)
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.add("Select all", symbol: "checkmark.rectangle.stack") { tab.selectAll() }
        menu.add("Select none", symbol: "rectangle.stack") { tab.selectNone() }
        menu.add("Invert selection", symbol: "arrow.left.arrow.right") { tab.invertSelection() }
        menu.addSeparator()
        menu.add("Copy path", symbol: "link") { tab.copyPathOfSelection() }
        menu.add("Show in Finder", symbol: "macwindow") { tab.showInFinder() }
        menu.add("Open in Terminal", symbol: "terminal") { tab.openInTerminal() }
        menu.addSeparator()
        menu.add("Properties", symbol: "info.circle") { tab.showProperties() }
        return menu
    }
}

private struct ShareButton: View {
    let urls: [URL]
    @State private var frame: CGRect = .zero

    var body: some View {
        IconButton(symbol: "square.and.arrow.up", help: "Share") {
            guard let view = NSApp.keyWindow?.contentView else { return }
            let rect = view.isFlipped ? frame : NSRect(
                x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height
            )
            NSSharingServicePicker(items: urls).show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}
