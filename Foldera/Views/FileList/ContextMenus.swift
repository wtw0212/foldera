import AppKit

/// Right-click menus for the file list.
enum ContextMenus {
    static func itemMenu(tab: BrowserTab, quickAccess: QuickAccess = .shared, openInNewTab: @escaping (URL) -> Void) -> NSMenu {
        let menu = NSMenu()
        let items = tab.selectedItems
        let single = items.count == 1 ? items.first : nil

        menu.add(L10n.text("Open"), symbol: "arrow.up.forward.app") { tab.openSelection() }
        if let folder = single, folder.isNavigable {
            menu.add(L10n.text("Open in new tab"), symbol: "plus.square.on.square") { openInNewTab(folder.url) }
        }
        if let file = single, !file.isNavigable, !tab.isRemote {
            let openWith = NSMenuItem(title: L10n.text("Open with"), action: nil, keyEquivalent: "")
            openWith.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
            openWith.submenu = openWithMenu(for: file.url)
            menu.addItem(openWith)
        }
        menu.addSeparator()
        menu.add(L10n.text("Cut"), symbol: "scissors") { tab.cutSelection() }
        menu.add(L10n.text("Copy"), symbol: "doc.on.doc") { tab.copySelection() }
        if let folder = single, folder.isNavigable {
            menu.add(L10n.text("Paste into folder"), symbol: "doc.on.clipboard", enabled: tab.canPaste) {
                tab.paste(into: folder.url)
            }
        }
        menu.addSeparator()
        if tab.isRecent {
            if single != nil {
                menu.add(L10n.text("Open file location"), symbol: "folder") { tab.openItemLocation() }
            }
            menu.add(L10n.text("Remove from Recent"), symbol: "clock.badge.xmark") { tab.removeSelectionFromRecent() }
        } else {
            menu.add(items.count > 1 ? L10n.format("rename.items.menu", items.count) : L10n.text("Rename"), symbol: "character.cursor.ibeam") { tab.beginRename() }
            menu.add(L10n.text("Delete"), symbol: "trash") { tab.trashSelection() }
        }
        menu.addSeparator()
        let archives = tab.selectedArchives
        if !archives.isEmpty {
            menu.add(L10n.text("Extract here"), symbol: "arrow.up.bin") { tab.extractSelection(.here) }
            if archives.count == 1 {
                menu.add(L10n.format("Extract to “%@”", Archives.baseName(of: archives[0])), symbol: "folder.badge.plus") { tab.extractSelection(.ownFolder) }
            } else {
                menu.add(L10n.text("Extract each to separate folders"), symbol: "folder.badge.plus") { tab.extractSelection(.ownFolder) }
            }
        }
        if tab.canCompressSelection {
            menu.add(L10n.text("Compress to ZIP file"), symbol: "doc.zipper") { tab.compressSelection(.zip) }
            if Archives.canCreate7z {
                menu.add(L10n.text("Compress to 7z file"), symbol: "doc.zipper") { tab.compressSelection(.sevenZip) }
            }
            menu.add(L10n.text("Compress to…"), symbol: "lock.doc") { tab.compressSelectionWithOptions() }
        }
        menu.addSeparator()
        let folders = tab.isRemote ? [] : items.filter(\.isNavigable)
        if !folders.isEmpty {
            if folders.allSatisfy({ quickAccess.isPinned($0.url) }) {
                menu.add(L10n.text("Unpin from Quick access"), symbol: "pin.slash") { folders.forEach { quickAccess.unpin($0.url) } }
            } else {
                menu.add(L10n.text("Pin to Quick access"), symbol: "pin") { folders.forEach { quickAccess.pin($0.url) } }
            }
        }
        menu.add(L10n.text("Copy as path"), symbol: "link") { tab.copyPathOfSelection() }
        if !tab.isRemote {
            menu.add(L10n.text("Show in Finder"), symbol: "macwindow") { tab.showInFinder() }
        }
        menu.addSeparator()
        menu.add(L10n.text("Properties"), symbol: "info.circle") { tab.showProperties() }
        return menu
    }

    static func backgroundMenu(tab: BrowserTab, quickAccess: QuickAccess = .shared, settings: AppSettings = .shared) -> NSMenu {
        let menu = NSMenu()

        let sortItem = NSMenuItem(title: L10n.text("Sort by"), action: nil, keyEquivalent: "")
        sortItem.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
        let sortMenu = NSMenu()
        for field in SortField.allCases {
            sortMenu.add(field.title, checked: tab.sort.field == field) { tab.sort.field = field }
        }
        sortMenu.addSeparator()
        sortMenu.add(L10n.text("Ascending"), checked: tab.sort.ascending) { tab.sort.ascending = true }
        sortMenu.add(L10n.text("Descending"), checked: !tab.sort.ascending) { tab.sort.ascending = false }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        menu.add(L10n.text("Show hidden items"), symbol: "eye", checked: settings.showHiddenFiles) { settings.showHiddenFiles.toggle() }
        menu.add(L10n.text("Refresh"), symbol: "arrow.clockwise") { tab.reload() }
        if tab.isRecent {
            menu.addSeparator()
            menu.add(L10n.text("Clear Recent Items"), symbol: "clock.badge.xmark") {
                tab.recents.clear()
                tab.reload()
            }
            return menu
        }
        menu.addSeparator()
        menu.add(L10n.text("Paste"), symbol: "doc.on.clipboard", enabled: tab.canPaste) { tab.paste() }
        menu.addSeparator()
        let newItem = NSMenuItem(title: L10n.text("New"), action: nil, keyEquivalent: "")
        newItem.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        let newMenu = NSMenu()
        newMenu.add(L10n.text("Folder"), symbol: "folder") { tab.newFolder() }
        newMenu.add(L10n.text("Text Document"), symbol: "doc.text") { tab.newTextDocument() }
        newItem.submenu = newMenu
        menu.addItem(newItem)
        menu.addSeparator()
        if tab.isRemote {
            menu.add(L10n.text("Open in Terminal (SSH)"), symbol: "terminal") { tab.openInTerminal() }
        } else {
            if quickAccess.isPinned(tab.url) {
                menu.add(L10n.text("Unpin from Quick access"), symbol: "pin.slash") { quickAccess.unpin(tab.url) }
            } else {
                menu.add(L10n.text("Pin to Quick access"), symbol: "pin") { quickAccess.pin(tab.url) }
            }
            menu.add(L10n.text("Open in Terminal"), symbol: "terminal") { tab.openInTerminal() }
            menu.add(L10n.text("Show in Finder"), symbol: "macwindow") { tab.showInFinder() }
        }
        menu.add(L10n.text("Properties"), symbol: "info.circle") { tab.showProperties() }
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
            if app == defaultApp { title += L10n.text(" (default)") }
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            menu.addItem(ClosureMenuItem(title, image: icon) {
                workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            })
        }
        if apps.isEmpty {
            menu.add(L10n.text("No applications"), enabled: false) {}
        }
        return menu
    }
}
