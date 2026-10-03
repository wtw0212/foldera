import Foundation
import Testing
@testable import Foldera

@MainActor
struct ExplorerWindowModelTests {
    @Test func closingActiveTabChoosesItsNeighbourAndKeepsLastTab() {
        let model = ExplorerWindowModel(url: BrowserTab.thisMacURL)
        let first = model.activeTabID
        model.newTab(url: BrowserTab.thisMacURL)
        let second = model.activeTabID
        model.newTab(url: BrowserTab.thisMacURL)
        let third = model.activeTabID
        model.activeTabID = second
        #expect(model.closeTab(second) && model.activeTabID == third)
        #expect(model.closeTab(first) && model.activeTabID == third)
        #expect(!model.closeTab(third) && model.tabs.count == 1)
        #expect(!model.closeTab(UUID()))
    }

    @Test func shortcutsCycleAndCommandNineSelectsLastTab() {
        let model = ExplorerWindowModel(url: BrowserTab.thisMacURL)
        for _ in 0..<3 { model.newTab(url: BrowserTab.thisMacURL) }
        model.selectTab(number: 1)
        #expect(model.activeTabID == model.tabs[0].id)
        model.selectTab(offset: -1)
        #expect(model.activeTabID == model.tabs[3].id)
        model.selectTab(offset: 1)
        #expect(model.activeTabID == model.tabs[0].id)
        model.selectTab(number: 9)
        #expect(model.activeTabID == model.tabs[3].id)
        model.selectTab(number: 2)
        #expect(model.activeTabID == model.tabs[1].id)
    }

    @Test func duplicateAndReorderPreserveActiveIdentity() {
        let model = ExplorerWindowModel(url: BrowserTab.thisMacURL)
        let first = model.activeTabID
        model.duplicateActiveTab()
        let duplicate = model.activeTabID
        #expect(duplicate != first && model.primaryTab.url == BrowserTab.thisMacURL)
        model.moveTab(duplicate, before: first)
        #expect(model.tabs.map(\.id) == [duplicate, first] && model.activeTabID == duplicate)
        model.moveTab(first, before: first)
        model.moveTab(UUID(), before: first)
        #expect(model.tabs.map(\.id) == [duplicate, first])
    }

    @Test func secondaryPaneRetainsItsLocationWhenReopened() throws {
        let directory = try TestDirectory()
        let model = ExplorerWindowModel(url: BrowserTab.thisMacURL)
        model.toggleDualPane()
        let secondary = try #require(model.secondaryTab)
        secondary.navigate(to: directory.url)
        model.focusedPane = .secondary
        model.toggleDualPane()
        #expect(model.focusedPane == .primary && model.otherTab == nil)
        model.toggleDualPane()
        #expect(model.secondaryTab === secondary && model.secondaryTab?.url == directory.url)
        #expect(model.activeTab === model.primaryTab)
    }

    @Test func focusRequestsIncrementTokens() {
        let model = ExplorerWindowModel(url: BrowserTab.thisMacURL)
        model.focusSearch()
        model.focusSearch()
        model.primaryTab.requestListFocus()
        #expect(model.focusSearchToken == 2 && model.primaryTab.focusListToken == 1)
    }
}
