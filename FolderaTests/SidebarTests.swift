import Foundation
import Testing
@testable import Foldera

@MainActor
struct SidebarTests {
    @Test func quickAccessDefaultsAndExplicitEmptyPinsAreDifferent() throws {
        let preferences = try TestPreferences()
        #expect(QuickAccess(defaults: preferences.defaults).urls == StandardLocations.pinned.map(\.url.normalizedFileURL))
        preferences.defaults.set([String](), forKey: "quickAccessPins")
        #expect(QuickAccess(defaults: preferences.defaults).urls.isEmpty)
    }

    @Test func pinningNormalizesDeduplicatesAndPersistsOrder() throws {
        let directory = try TestDirectory()
        let preferences = try TestPreferences()
        preferences.defaults.set([String](), forKey: "quickAccessPins")
        let pins = QuickAccess(defaults: preferences.defaults)
        let a = try directory.folder("a"), b = try directory.folder("b")
        pins.pin(a)
        pins.pin(a.normalizedFileURL)
        pins.pin(b)
        #expect(pins.urls == [a.normalizedFileURL, b] && pins.isPinned(a))
        let restored = QuickAccess(defaults: preferences.defaults)
        #expect(restored.urls == pins.urls && restored.isPinned(a))
        restored.pin(a)
        #expect(restored.urls == pins.urls)
        pins.unpin(a)
        #expect(pins.urls == [b] && !pins.isPinned(a))
    }

    @Test func droppedPinsReorderWithoutDuplicatesOrSelfDrops() throws {
        let preferences = try TestPreferences()
        preferences.defaults.set(["/a", "/b", "/c"], forKey: "quickAccessPins")
        let pins = QuickAccess(defaults: preferences.defaults)
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")
        pins.insert([c, c], before: a)
        #expect(pins.urls == [c, a, b])
        pins.insert([a], before: nil, atStart: true)
        #expect(pins.urls == [a, c, b])
        pins.insert([a], before: a)
        pins.insert([], before: nil)
        #expect(pins.urls == [a, c, b])
        pins.insert([a], before: nil)
        #expect(QuickAccess(defaults: preferences.defaults).urls == [c, b, a])
    }

    @Test func onlyRealFoldersCanBePinned() throws {
        let directory = try TestDirectory()
        let folder = try directory.folder("folder"), package = try directory.folder("Demo.app")
        let file = try directory.file("file.txt")
        #expect(QuickAccess.pinnableFolders([folder, package, file, directory.path("missing")]) == [folder])
    }

    @Test func folderTreeExpandsDepthFirstAndKeepsSectionsIndependent() throws {
        let directory = try TestDirectory()
        let a = try directory.folder("folder2/child"), b = try directory.folder("folder10")
        try directory.folder("Demo.app")
        try directory.file("file.txt")
        let tree = FolderTree()
        #expect(tree.knownChildren("one") == nil && tree.rows(under: directory.url, section: "one").isEmpty)
        tree.toggle("one", url: directory.url)
        #expect(tree.knownChildren("one") == [a.deletingLastPathComponent().normalizedFileURL, b])
        tree.toggle("one/folder2", url: a.deletingLastPathComponent())
        let rows = tree.rows(under: directory.url, section: "one")
        #expect(rows.map(\.url) == [a.deletingLastPathComponent().normalizedFileURL, a, b])
        #expect(rows.map(\.depth) == [1, 2, 1])
        #expect(tree.rows(under: directory.url, section: "two").isEmpty)
        tree.toggle("one", url: directory.url)
        #expect(!tree.isExpanded("one") && tree.rows(under: directory.url, section: "one").isEmpty)
    }

    @Test func cloudDetectionExcludesHiddenFilesAndArchivedICloudFolders() throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let drive = try directory.folder("OneDrive-Personal")
        try directory.folder("Dropbox")
        try directory.folder("iCloud Drive (Archive)")
        try directory.folder(".hidden")
        try directory.file("not-a-drive")
        let drives = CloudDrives(defaults: preferences.defaults, storageFolder: directory.url)
        #expect(drives.detected.map(\.title) == ["Dropbox", "OneDrive - Personal"])
        #expect(drives.missingProviders.map(\.name) == ["Google Drive", "Box"])
        drives.add(drive)
        #expect(drives.added.isEmpty)
        try FileManager.default.removeItem(at: drive)
        drives.refresh()
        #expect(drives.detected.map(\.title) == ["Dropbox"])
        #expect(drives.missingProviders.contains { $0.name == "OneDrive" })
    }

    @Test func customCloudDrivesPersistAndMissingDrivesAreHidden() throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let drive = try directory.folder("custom")
        let storage = try directory.folder("storage")
        let drives = CloudDrives(defaults: preferences.defaults, storageFolder: storage)
        drives.add(drive)
        drives.add(drive.appendingPathComponent(".", isDirectory: true))
        #expect(drives.added == [drive] && drives.isAdded(drive))
        let restored = CloudDrives(defaults: preferences.defaults, storageFolder: storage)
        #expect(restored.added == [drive] && restored.isAdded(drive))
        restored.add(drive)
        #expect(restored.added == [drive])
        #expect(drives.locations.map(\.url) == [drive])
        try FileManager.default.removeItem(at: drive)
        #expect(drives.locations.isEmpty && drives.isAdded(drive))
        drives.remove(drive)
        #expect(!drives.isAdded(drive) && preferences.defaults.stringArray(forKey: "addedCloudDrives") == [])
    }
}
