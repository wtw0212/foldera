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
        return Location(url: url, title: "Home", symbol: "home_filled", tint: Color(nsColor: .init(hex: 0x4F8BD6)))
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
            return Location(url: url, title: title, symbol: symbol, tint: Color(nsColor: .init(hex: tint)))
        }
    }
}

/// Mounted volumes, kept up to date as disks are mounted, unmounted or renamed.
@Observable
final class VolumeMonitor {
    static let shared = VolumeMonitor()

    private(set) var volumes: [Location] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
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

    /// Ejects (unmounts) a removable volume.
    func eject(_ location: Location) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: location.url)
        } catch {
            BrowserTab.present(error)
        }
    }
}
