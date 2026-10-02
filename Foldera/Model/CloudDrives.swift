import AppKit
import Observation
import SwiftUI

/// Cloud drives for the navigation pane: File Provider folders that OneDrive, Google Drive, Dropbox,
/// Box and others create in ~/Library/CloudStorage, plus any folder the user adds (a mounted share,
/// an rclone mount, an older app's sync folder…).
@Observable
final class CloudDrives {
    static let shared = CloudDrives()

    private(set) var detected: [Location] = []
    private(set) var added: [URL]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private static let key = "addedCloudDrives"

    /// Apps that sync into ~/Library/CloudStorage, offered when not installed yet.
    struct Provider: Identifiable {
        let name: String
        let folderPrefix: String
        let download: URL
        var id: String { name }
    }

    static let providers = [
        Provider(name: "OneDrive", folderPrefix: "OneDrive", download: URL(string: "https://www.microsoft.com/microsoft-365/onedrive/download")!),
        Provider(name: "Google Drive", folderPrefix: "GoogleDrive", download: URL(string: "https://www.google.com/drive/download/")!),
        Provider(name: "Dropbox", folderPrefix: "Dropbox", download: URL(string: "https://www.dropbox.com/install")!),
        Provider(name: "Box", folderPrefix: "Box", download: URL(string: "https://www.box.com/resources/downloads")!),
    ]

    private static var storageFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
    }

    private init() {
        added = (UserDefaults.standard.stringArray(forKey: Self.key) ?? []).map { URL(fileURLWithPath: $0) }
        refresh()
        // Pick up drives set up while Foldera is running.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    /// Everything to show, detected drives first.
    var locations: [Location] {
        let detectedURLs = Set(detected.map(\.url))
        return detected + added
            .filter { !detectedURLs.contains($0) && FileManager.default.fileExists(atPath: $0.path) }
            .map { Self.location(for: $0, title: FileManager.default.displayName(atPath: $0.path)) }
    }

    /// Providers with no folder in ~/Library/CloudStorage yet.
    var missingProviders: [Provider] {
        let names = detected.map(\.url.lastPathComponent)
        return Self.providers.filter { provider in !names.contains { $0.hasPrefix(provider.folderPrefix) } }
    }

    func isAdded(_ url: URL) -> Bool { added.contains(url.normalizedFileURL) }

    func add(_ url: URL) {
        let url = url.normalizedFileURL
        guard !added.contains(url), !detected.contains(where: { $0.url == url }) else { return }
        added.append(url)
        save()
    }

    func remove(_ url: URL) {
        added.removeAll { $0 == url.normalizedFileURL }
        save()
    }

    /// Asks for a folder to show as a cloud drive.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a cloud or network folder to show in the navigation pane."
        panel.directoryURL = FileManager.default.fileExists(atPath: Self.storageFolder.path) ? Self.storageFolder : URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(add)
    }

    func refresh() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Self.storageFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let found = folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            // iCloud Drive has its own entry; "iCloud…" folders here are archived copies macOS leaves behind.
            .filter { !$0.lastPathComponent.hasPrefix("iCloud") }
            .map(\.normalizedFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Self.location(for: $0, title: Self.title(forStorageFolder: $0)) }
        if found != detected { detected = found }
    }

    private func save() {
        UserDefaults.standard.set(added.map(\.path), forKey: Self.key)
    }

    /// "OneDrive-Personal" → "OneDrive - Personal", "GoogleDrive-me@gmail.com" → "Google Drive - me@gmail.com".
    static func title(forStorageFolder url: URL) -> String {
        let display = FileManager.default.displayName(atPath: url.path)
        let folder = url.lastPathComponent
        guard display == folder else { return display } // the provider supplied a nicer name
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let provider = providers.first { $0.folderPrefix == parts[0] }?.name ?? parts[0]
        guard parts.count == 2, parts[1] != parts[0] else { return provider } // "Box-Box" → "Box"
        return "\(provider) - \(parts[1])"
    }

    private static func location(for url: URL, title: String) -> Location {
        let name = url.lastPathComponent.lowercased()
        let tint: UInt32 = if name.hasPrefix("onedrive") { 0x0A64D8 }
            else if name.hasPrefix("googledrive") || name.hasPrefix("google drive") { 0x1FA463 }
            else if name.hasPrefix("dropbox") { 0x0061FE }
            else if name.hasPrefix("box") { 0x0061D5 }
            else { 0x3D9BE9 }
        return Location(url: url, title: title, symbol: "cloud_filled", tint: Color(nsColor: .init(hex: tint)))
    }
}
