import AppKit
import Observation
import SwiftUI

struct Location: Identifiable, Hashable {
    let url: URL
    let title: String
    let symbol: String
    let tint: Color

    var id: URL { url }
}

/// Fixed places shown in the navigation pane.
enum StandardLocations {
    private static let fileManager = FileManager.default

    static var home: Location {
        let url = fileManager.homeDirectoryForCurrentUser
        return Location(url: url, title: L10n.text("Home"), symbol: "home_filled", tint: Color(nsColor: .init(hex: 0x4F8BD6)))
    }

    static var iCloudDrive: Location? {
        let url = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return Location(url: url, title: "iCloud Drive", symbol: "cloud_filled", tint: Color(nsColor: .init(hex: 0x3D9BE9)))
    }

    static var pinned: [Location] {
        let entries: [(FileManager.SearchPathDirectory, String, String, UInt32)] = [
            (.desktopDirectory, "Desktop", "desktop_filled", 0x3A86D9),
            (.downloadsDirectory, "Downloads", "arrow_circle_down_filled", 0x2E9D57),
            (.documentDirectory, "Documents", "document_filled", 0x6A7B8F),
            (.picturesDirectory, "Pictures", "image_filled", 0x2F8FD8),
            (.musicDirectory, "Music", "music_note_2_filled", 0xE8663C),
            (.moviesDirectory, "Movies", "video_filled", 0x8B5CD6),
            (.applicationDirectory, "Applications", "apps_filled", 0x4F8BD6),
        ]
        return entries.compactMap { directory, title, symbol, tint in
            let domain: FileManager.SearchPathDomainMask = directory == .applicationDirectory ? .localDomainMask : .userDomainMask
            guard let url = fileManager.urls(for: directory, in: domain).first else { return nil }
            return Location(url: url, title: L10n.text(title), symbol: symbol, tint: Color(nsColor: .init(hex: tint)))
        }
    }
}

/// Mounted volumes, kept up to date as disks are mounted, unmounted or renamed.
@Observable
final class VolumeMonitor {
    static let shared = VolumeMonitor()

    private(set) var volumes: [Location] = []
    /// Mounted file-server shares (SMB, AFP, NFS, WebDAV), shown under Network.
    private(set) var networkVolumeURLs: Set<URL> = []
    var localVolumes: [Location] { volumes.filter { !networkVolumeURLs.contains($0.url) } }
    var networkVolumes: [Location] { volumes.filter { networkVolumeURLs.contains($0.url) } }
    private(set) var ejecting: [URL: String] = [:]
    private(set) var lastEjectedName: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let ejectDevice: @Sendable (URL) throws -> Void

    init(observe: Bool = true, ejectDevice: @escaping @Sendable (URL) throws -> Void = { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) }) {
        self.ejectDevice = ejectDevice
        guard observe else { return }
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didMountNotification { self?.dismissEjectionNotice() }
                    self?.refresh()
                }
            })
        }
    }

    isolated deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        networkVolumeURLs = Set(urls.filter { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false })
        volumes = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let external = values?.volumeIsRemovable == true || values?.volumeIsEjectable == true || values?.volumeIsInternal == false
            return Location(
                url: url,
                title: values?.volumeLocalizedName ?? url.lastPathComponent,
                symbol: "hard_drive_filled",
                // Removable and external drives get a blue tint so they stand out from the startup disk.
                tint: Color(nsColor: .init(hex: external ? 0x3A86D9 : 0x7A8594))
            )
        }
    }

    func isEjecting(_ location: Location) -> Bool { ejecting[location.url.normalizedFileURL] != nil }

    func dismissEjectionNotice() { lastEjectedName = nil }

    /// macOS may wait for disk writes and volume notifications; keep the main actor responsive.
    func eject(_ location: Location) {
        let url = location.url.normalizedFileURL, name = location.title, eject = ejectDevice
        guard ejecting[url] == nil else { return }
        ejecting[url] = name
        lastEjectedName = nil
        Task {
            do {
                try await Task.detached { try eject(url) }.value
                ejecting.removeValue(forKey: url)
                if !observers.isEmpty { refresh() }
                lastEjectedName = name
            } catch {
                ejecting.removeValue(forKey: url)
                BrowserTab.present(error)
            }
        }
    }
}
