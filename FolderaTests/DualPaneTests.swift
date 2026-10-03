import Foundation
import Testing
@testable import Foldera

@MainActor
struct DualPaneTests {
    @Test func f5CopiesSelectionIntoOtherPane() async throws {
        let fm = FileManager.default
        let directory = try TestDirectory()
        let root = directory.url
        try fm.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("note.txt"))

        let model = ExplorerWindowModel(url: root)
        model.toggleDualPane()
        #expect(model.isDualPane)
        let secondary = try #require(model.secondaryTab)
        secondary.navigate(to: root.appendingPathComponent("target"))

        let primary = model.primaryTab
        try await eventually { !primary.isLoading }
        try #require(primary.loadError == nil)
        primary.selection = [root.appendingPathComponent("note.txt").normalizedFileURL]
        #expect(model.activeTab === primary)
        #expect(model.otherTab === secondary)

        model.transferToOtherPane(.copy)
        try await eventually { fm.fileExists(atPath: root.appendingPathComponent("target/note.txt").path) }
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
