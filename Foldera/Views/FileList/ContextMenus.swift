import AppKit

/// Right-click menus for the file list.
enum ContextMenus {
    static func itemMenu(tab: BrowserTab, openInNewTab: @escaping (URL) -> Void) -> NSMenu {
        let menu = NSMenu()
        let items = tab.selectedItems
        let single = items.count == 1 ? items.first : nil

        menu.add("Open", symbol: "arrow.up.forward.app") { tab.openSelection() }
        if let folder = single, folder.isNavigable {
            menu.add("Open in new tab", symbol: "plus.square.on.square") { openInNewTab(folder.url) }
        }
        if let file = single, !file.isNavigable {
            let openWith = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
            openWith.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
            openWith.submenu = openWithMenu(for: file.url)
            menu.addItem(openWith)
        }
        menu.addSeparator()
        menu.add("Cut", symbol: "scissors") { tab.cutSelection() }
        menu.add("Copy", symbol: "doc.on.doc") { tab.copySelection() }
        if let folder = single, folder.isNavigable {
            menu.add("Paste into folder", symbol: "doc.on.clipboard", enabled: tab.canPaste) {
                tab.paste(into: folder.url)
            }
        }
        menu.addSeparator()
        menu.add(items.count > 1 ? "Rename \(items.count) items…" : "Rename", symbol: "character.cursor.ibeam") { tab.beginRename() }
        menu.add("Delete", symbol: "trash") { tab.trashSelection() }
        menu.addSeparator()
        let folders = items.filter(\.isNavigable)
        if !folders.isEmpty {
            let quickAccess = QuickAccess.shared
            if folders.allSatisfy({ quickAccess.isPinned($0.url) }) {
                menu.add("Unpin from Quick access", symbol: "pin.slash") { folders.forEach { quickAccess.unpin($0.url) } }
            } else {
                menu.add("Pin to Quick access", symbol: "pin") { folders.forEach { quickAccess.pin($0.url) } }
            }
        }
        menu.add("Copy as path", symbol: "link") { tab.copyPathOfSelection() }
        menu.add("Show in Finder", symbol: "macwindow") { tab.showInFinder() }
        menu.addSeparator()
        menu.add("Properties", symbol: "info.circle") { tab.showProperties() }
        return menu
    }

    static func backgroundMenu(tab: BrowserTab) -> NSMenu {
        let menu = NSMenu()
        let settings = AppSettings.shared

        let sortItem = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        sortItem.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
        let sortMenu = NSMenu()
        for field in SortField.allCases {
            sortMenu.add(field.title, checked: tab.sort.field == field) { tab.sort.field = field }
        }
        sortMenu.addSeparator()
        sortMenu.add("Ascending", checked: tab.sort.ascending) { tab.sort.ascending = true }
        sortMenu.add("Descending", checked: !tab.sort.ascending) { tab.sort.ascending = false }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        menu.add("Show hidden items", symbol: "eye", checked: settings.showHiddenFiles) { settings.showHiddenFiles.toggle() }
        menu.add("Refresh", symbol: "arrow.clockwise") { tab.reload() }
        menu.addSeparator()
        menu.add("Paste", symbol: "doc.on.clipboard", enabled: tab.canPaste) { tab.paste() }
        menu.addSeparator()
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        newItem.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        let newMenu = NSMenu()
        newMenu.add("Folder", symbol: "folder") { tab.newFolder() }
        newMenu.add("Text Document", symbol: "doc.text") { tab.newTextDocument() }
        newItem.submenu = newMenu
        menu.addItem(newItem)
        menu.addSeparator()
        let quickAccess = QuickAccess.shared
        if quickAccess.isPinned(tab.url) {
            menu.add("Unpin from Quick access", symbol: "pin.slash") { quickAccess.unpin(tab.url) }
        } else {
            menu.add("Pin to Quick access", symbol: "pin") { quickAccess.pin(tab.url) }
        }
        menu.add("Open in Terminal", symbol: "terminal") { tab.openInTerminal() }
        menu.add("Show in Finder", symbol: "macwindow") { tab.showInFinder() }
        menu.add("Properties", symbol: "info.circle") { tab.showProperties() }
        return menu
    }

    private static func openWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: url)
        let apps = workspace.urlsForApplications(toOpen: url)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for app in apps {
            var title = FileManager.default.displayName(atPath: app.path)
            if app == defaultApp { title += " (default)" }
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            menu.addItem(ClosureMenuItem(title, image: icon) {
                workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            })
        }
        if apps.isEmpty {
            menu.add("No applications", enabled: false) {}
        }
        return menu
    }
}
