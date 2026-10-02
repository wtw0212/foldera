import Foundation
import Testing
@testable import Foldera

@MainActor
struct NavigationFeatureTests {
    @Test func backgroundTabsOpenInOrderAfterTheActiveTab() {
        let model = ExplorerWindowModel(url: URL(fileURLWithPath: "/"))
        let first = model.activeTabID
        model.newTab(url: URL(fileURLWithPath: "/tmp"))
        let active = model.activeTabID
        model.activeTabID = first
        model.newTab(url: URL(fileURLWithPath: "/usr"), activate: false)
        model.newTab(url: URL(fileURLWithPath: "/var"), activate: false)
        #expect(model.activeTabID == first)
        #expect(model.tabs.map(\.url.path) == ["/", "/usr", "/var", "/tmp"])
        // Switching tabs starts a fresh run of background tabs.
        model.activeTabID = active
        model.newTab(url: URL(fileURLWithPath: "/bin"), activate: false)
        #expect(model.tabs.map(\.url.path).last == "/bin")
    }

    @Test func cloudStorageFolderTitles() {
        let base = URL(fileURLWithPath: "/nonexistent/CloudStorage")
        #expect(CloudDrives.title(forStorageFolder: base.appendingPathComponent("OneDrive-Personal")) == "OneDrive - Personal")
        #expect(CloudDrives.title(forStorageFolder: base.appendingPathComponent("GoogleDrive-me@example.com")) == "Google Drive - me@example.com")
        #expect(CloudDrives.title(forStorageFolder: base.appendingPathComponent("Box-Box")) == "Box")
        #expect(CloudDrives.title(forStorageFolder: base.appendingPathComponent("Dropbox")) == "Dropbox")
    }

    @Test func addressCommandParsing() {
        #expect(AddressCommand.split("  code  src/app ") == ("code", "src/app"))
        #expect(AddressCommand.split("terminal") == ("terminal", ""))
        #expect(AddressCommand.shellQuoted("/Users/me/it's here") == "'/Users/me/it'\\''s here'")
        #expect(AddressCommand.executableOnPath("ls"))
        #expect(!AddressCommand.executableOnPath("definitely-not-a-command-xyz"))
        #expect(!AddressCommand.executableOnPath("../ls"))
        #expect(AddressCommand.application(named: "safari")?.lastPathComponent == "Safari.app")
    }
}
