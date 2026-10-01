import Foundation
import Testing
@testable import Foldera

@MainActor
struct DualPaneTests {
    private func waitUntilLoaded(_ tab: BrowserTab) async {
        for _ in 0..<100 where tab.isLoading || tab.items.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func f5CopiesSelectionIntoOtherPane() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaDual-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("note.txt"))

        let model = ExplorerWindowModel(url: root)
        model.toggleDualPane()
        #expect(model.isDualPane)
        let secondary = try #require(model.secondaryTab)
        secondary.navigate(to: root.appendingPathComponent("target"))

        let primary = model.primaryTab
        await waitUntilLoaded(primary)
        primary.selection = [root.appendingPathComponent("note.txt").normalizedFileURL]
        #expect(model.activeTab === primary)
        #expect(model.otherTab === secondary)

        model.transferToOtherPane(.copy)
        for _ in 0..<100 where !fm.fileExists(atPath: root.appendingPathComponent("target/note.txt").path) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(fm.fileExists(atPath: root.appendingPathComponent("target/note.txt").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("note.txt").path))
    }

    @Test func focusSwitchesActiveTab() {
        let model = ExplorerWindowModel(url: FileManager.default.temporaryDirectory)
        #expect(model.otherTab == nil)
        model.toggleDualPane()
        model.focusedPane = .secondary
        #expect(model.activeTab === model.secondaryTab)
        #expect(model.otherTab === model.primaryTab)
        model.toggleDualPane()
        #expect(model.activeTab === model.primaryTab)
    }
}
