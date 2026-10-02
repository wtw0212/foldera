import AppKit
import Observation
import SwiftUI

/// State for one explorer window: its tabs and window-level focus requests.
@Observable
final class ExplorerWindowModel {
    private(set) var tabs: [BrowserTab]
    var activeTabID: BrowserTab.ID {
        didSet { if activeTabID != oldValue { lastBackgroundTabID = nil } }
    }
    /// The newest tab opened in the background from the active tab, so further ones line up after it (like a browser).
    @ObservationIgnored private var lastBackgroundTabID: BrowserTab.ID?
    var isEditingAddress = false
    /// Bumped to move keyboard focus to the search box.
    private(set) var focusSearchToken = 0

    /// The first window opens at `-initialPath <path>` when given (e.g. `open Foldera.app --args -initialPath ~/Downloads`).
    static var defaultURL: URL {
        if let path = UserDefaults.standard.string(forKey: "initialPath") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return AppSettings.shared.startLocation.url
    }

    init(url: URL = ExplorerWindowModel.defaultURL) {
        let tab = BrowserTab(url: url)
        tabs = [tab]
        activeTabID = tab.id
    }

    enum Pane { case primary, secondary }

    /// Two side-by-side file panes, like Double Commander. The primary pane shows the selected tab.
    private(set) var isDualPane = false
    /// The right-hand pane's own location and history; kept while dual pane is off.
    private(set) var secondaryTab: BrowserTab?
    /// The pane that the address bar, command bar, status bar and menu commands act on.
    var focusedPane: Pane = .primary

    /// The selected tab in the tab strip (the left pane in dual-pane mode).
    var primaryTab: BrowserTab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    /// The tab that commands act on: the focused pane's tab.
    var activeTab: BrowserTab {
        if isDualPane, focusedPane == .secondary, let secondaryTab { return secondaryTab }
        return primaryTab
    }

    /// The pane that isn't focused, when dual pane is on.
    var otherTab: BrowserTab? {
        guard isDualPane, let secondaryTab else { return nil }
        return focusedPane == .primary ? secondaryTab : primaryTab
    }

    func toggleDualPane() {
        if !isDualPane, secondaryTab == nil {
            secondaryTab = BrowserTab(url: primaryTab.url)
        }
        isDualPane.toggle()
        focusedPane = .primary
    }

    /// F5 / F6: copy or move the focused pane's selection into the other pane's folder.
    func transferToOtherPane(_ kind: FileTransfer.Kind) {
        guard let target = otherTab else { return }
        let source = activeTab
        let urls = source.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let destination = target.url
        Task {
            let result = await FileTransfers.shared.run(kind, urls, into: destination)
            FileUndo.shared.record(FileChange(result, kind: kind), name: kind == .copy ? "Copy" : "Move")
            target.reload()
            source.reload()
        }
    }

    /// Opens a tab after the active one. `activate: false` (middle-click) opens it in the background.
    func newTab(url: URL? = nil, activate: Bool = true) {
        let tab = BrowserTab(url: url ?? AppSettings.shared.startLocation.url)
        let anchor = activate ? nil : lastBackgroundTabID.flatMap { id in tabs.firstIndex { $0.id == id } }
        let index = (anchor ?? tabs.firstIndex { $0.id == activeTabID }).map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)
        if activate { activeTabID = tab.id } else { lastBackgroundTabID = tab.id }
    }

    func duplicateActiveTab() {
        newTab(url: primaryTab.url)
    }

    /// Closes a tab; returns false when it was the last one so the caller can close the window.
    @discardableResult
    func closeTab(_ id: BrowserTab.ID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        return true
    }

    func closeActiveTabOrWindow() {
        if !closeTab(activeTabID) {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activeTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        activeTabID = number >= 9 ? tabs[tabs.count - 1].id : tabs[min(number, tabs.count) - 1].id
    }

    func moveTab(_ id: BrowserTab.ID, before target: BrowserTab.ID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let to = tabs.firstIndex { $0.id == target } ?? tabs.endIndex
        tabs.insert(tab, at: to)
    }

    func focusSearch() {
        focusSearchToken += 1
    }
}

extension FocusedValues {
    @Entry var explorer: ExplorerWindowModel?
}
