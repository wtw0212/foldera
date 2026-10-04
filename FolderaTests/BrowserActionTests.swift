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
        let url = try directory.file(name)
        let event = try BrowserTab.propertiesEvent(for: url)
        #expect(event.attributeDescriptor(forKeyword: AEKeyword(keyEventClassAttr))?.typeCodeValue == OSType(kCoreEventClass))
        #expect(event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == OSType(kAEOpenDocuments))
        let target = try #require(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
        #expect(String(decoding: target.data, as: UTF8.self) == "com.apple.finder")
        let window = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        #expect(window.descriptorType == DescType(typeObjectSpecifier))
        #expect(window.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == 0x69776E64)
        let file = try #require(window.forKeyword(AEKeyword(keyAEContainer)))
        #expect(file.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == OSType(typeAlias))
        #expect(file.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formName))
        let location = try #require(file.forKeyword(AEKeyword(keyAEKeyData)))
        #expect(location.descriptorType == DescType(typeFileURL))
        #expect(String(decoding: location.data, as: UTF8.self) == url.absoluteString, "the name travels as data, unchanged")
    }

    /// Finder really resolves the event: each item, hostile names included, gets its information window.
    @Test func propertiesOpensFinderInformationWindows() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let errors = ErrorCollector()
        let urls = [try directory.file("\" & (do shell script \"touch pwned\") & \" 資料.txt"), try directory.folder("folder 📁")]
        defer { withExtendedLifetime(directory) { urls.forEach(FinderInfoWindows.close) } }
        let tab = BrowserTab(url: directory.url, settings: AppSettings(defaults: preferences.defaults))
        try await eventually { tab.items.count == 2 }
        tab.selection = Set(urls)
        tab.showProperties()
        #expect(errors.errors.isEmpty)
        // Finder opens the windows asynchronously.
        try await eventually { urls.allSatisfy(FinderInfoWindows.isOpen) }
        #expect(!FileManager.default.fileExists(atPath: directory.path("pwned").path))
        urls.forEach(FinderInfoWindows.close)
        try await eventually { urls.allSatisfy { !FinderInfoWindows.isOpen(for: $0) } }
    }

    @Test func propertiesRejectsNonFileURLs() throws {
        let remote = try #require(URL(string: "sftp://server/path"))
        #expect(throws: CocoaError.self) {
            try BrowserTab.propertiesEvent(for: remote)
        }
    }
}

/// Asks Finder about information windows through AppleScript's own `alias` resolution, so a test can check
/// what `propertiesEvent` opened without reusing its object specifier. The file is passed as data.
@MainActor
enum FinderInfoWindows {
    private static let script = NSAppleScript(source: """
    on isOpen(fileURL)
        set testFile to fileURL as alias
        with timeout of 5 seconds
            tell application "Finder" to return exists information window of testFile
        end timeout
    end isOpen
    on closeWindow(fileURL)
        set testFile to fileURL as alias
        tell application "Finder"
            -- Finder can close the window without replying; don't wait for its 120-second timeout.
            ignoring application responses
                close information window of testFile
            end ignoring
        end tell
    end closeWindow
    """)

    static func isOpen(for url: URL) -> Bool { call("isOpen", url)?.booleanValue == true }
    static func close(for url: URL) { _ = call("closeWindow", url) }

    private static func call(_ handler: String, _ url: URL) -> NSAppleEventDescriptor? {
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(fileURL: url), at: 1)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return script?.executeAppleEvent(event, error: nil)
    }
}
