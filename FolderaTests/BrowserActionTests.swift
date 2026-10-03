import Foundation
import Carbon
import Testing
@testable import Foldera

@MainActor
struct BrowserActionTests {
    @Test func selectionCommandsAndSortDefaultsFollowTheVisibleListing() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let a = try directory.file("a.txt"), b = try directory.file("b.zip")
        try directory.file(".hidden")
        let tab = BrowserTab(url: directory.url, settings: AppSettings(defaults: preferences.defaults))
        try await eventually { !tab.isLoading }
        tab.selectAll()
        #expect(tab.selection == [a, b] && tab.hasSelection && tab.selectedArchives == [b])
        tab.selection = [a]
        tab.invertSelection()
        #expect(tab.selection == [b])
        tab.selectNone()
        #expect(!tab.hasSelection)
        tab.setSort(.size)
        #expect(tab.sort == SortOrder(field: .size, ascending: false))
        tab.setSort(.size)
        #expect(tab.sort.ascending)
        tab.setSort(.name)
        #expect(tab.sort == SortOrder(field: .name))
        tab.setSort(.dateModified)
        #expect(!tab.sort.ascending)
    }

    @Test func renameRequestsSwitchBetweenInlineAndBulkRename() async throws {
        let directory = try TestDirectory()
        let a = try directory.file("a.txt"), b = try directory.file("b.txt")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.beginRename()
        #expect(tab.renameRequest == nil)
        tab.selection = [a]
        tab.beginRename()
        #expect(tab.renameRequest?.url == a && tab.bulkRenameItems == nil)
        tab.commitRename(of: a, to: "a.txt")
        #expect(tab.renameRequest == nil && FileOperations.exists(a))
        tab.selection = [a, b]
        tab.beginRename()
        #expect(Set(tab.bulkRenameItems?.map(\.url) ?? []) == [a, b])
        tab.beginRename(a)
        #expect(tab.renameRequest?.url == a && tab.selection == [a])
    }

    @Test func createAndRenameCommandsChangeFilesAndSelection() async throws {
        let directory = try TestDirectory()
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.newFolder()
        try await eventually { !tab.isLoading }
        #expect(tab.renameRequest?.url == directory.path("New folder"))
        tab.newTextDocument()
        try await eventually { !tab.isLoading }
        let document = directory.path("New Text Document.txt")
        #expect(tab.renameRequest?.url == document && tab.selection == [document])
        #expect(try Data(contentsOf: document).isEmpty)
        tab.commitRename(of: document, to: "renamed.txt")
        try await eventually { !tab.isLoading }
        #expect(tab.selection == [directory.path("renamed.txt")] && !FileOperations.exists(document))
    }

    @Test func openFolderSelectionNavigatesWithoutOpeningExternalApps() async throws {
        let directory = try TestDirectory()
        let folder = try directory.folder("folder")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [folder]
        tab.openSelection()
        #expect(tab.url == folder)
    }

    @Test func virtualDrivesPageDoesNotCreateFilesOrAllowPaste() {
        let tab = BrowserTab(url: BrowserTab.thisMacURL)
        tab.newFolder()
        tab.newTextDocument()
        #expect(tab.renameRequest == nil && !tab.canPaste && tab.items.isEmpty)
    }

    @Test(arguments: [
        "\"quoted\".txt", "back\\slash.txt", "line\nbreak\rname.txt",
        "separator\u{2028}paragraph\u{2029}.txt", "資料 📁.txt",
        "\" & (do shell script \"printf injected\") & \".txt"
    ])
    func propertiesPassesSpecialFilenamesAsFileURLData(_ name: String) throws {
        let directory = try TestDirectory()
        let urls = [try directory.file(name), try directory.file("plain.txt")]
        let event = try BrowserTab.propertiesEvent(for: urls)
        #expect(event.attributeDescriptor(forKeyword: AEKeyword(keyEventClassAttr))?.typeCodeValue == OSType(kCoreEventClass))
        #expect(event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == OSType(kAEOpenDocuments))
        let target = try #require(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
        #expect(target.descriptorType == DescType(typeApplicationBundleID))
        #expect(String(decoding: target.data, as: UTF8.self) == "com.apple.finder")
        let windows = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        #expect(windows.numberOfItems == urls.count)
        for (index, url) in urls.enumerated() {
            let window = try #require(windows.atIndex(index + 1))
            #expect(window.descriptorType == DescType(typeObjectSpecifier))
            #expect(window.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == OSType(cProperty))
            #expect(window.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formPropertyID))
            #expect(window.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == 0x69776E64)
            let file = try #require(window.forKeyword(AEKeyword(keyAEContainer)))
            #expect(file.descriptorType == DescType(typeObjectSpecifier))
            #expect(file.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == OSType(cObject))
            #expect(file.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formAbsolutePosition))
            let location = try #require(file.forKeyword(AEKeyword(keyAEKeyData)))
            #expect(location.descriptorType == DescType(typeFileURL))
            #expect(String(decoding: location.data, as: UTF8.self) == url.absoluteString)
        }
    }

    @Test func propertiesRejectsNonFileURLs() throws {
        let remote = try #require(URL(string: "sftp://server/path"))
        #expect(throws: CocoaError.self) {
            try BrowserTab.propertiesEvent(for: [remote])
        }
    }
}
