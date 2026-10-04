import AppKit

/// Dragging Foldera out of its DMG leaves the disk image mounted, and macOS never ejects it on its own.
/// When the installed copy launches, it ejects any mounted disk image that carries a copy of itself.
nonisolated enum InstallerDisk {
    /// Read-only, ejectable volumes (how a mounted DMG appears) with a top-level app of this bundle identifier,
    /// leaving out the volume the running app was opened from.
    static func volumes(app: URL = Bundle.main.bundleURL, identifier: String? = Bundle.main.bundleIdentifier,
                        mounted: [URL]? = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])) -> [URL] {
        // Opened straight from the DMG, macOS runs a translocated copy; the image is still in use.
        guard let identifier, !app.path.contains("/AppTranslocation/") else { return [] }
        let appVolume = try? app.resourceValues(forKeys: [.volumeURLKey]).volume?.standardizedFileURL
        return (mounted ?? []).filter { volume in
            guard volume.standardizedFileURL != appVolume,
                  let values = try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsEjectableKey]),
                  values.volumeIsReadOnly == true, values.volumeIsEjectable == true,
                  let items = try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)
            else { return false }
            return items.contains { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == identifier }
        }
    }

    /// Works off the main thread, since reading volumes and unmounting wait on the disks.
    /// Failures are left alone: the user can still eject the image themselves.
    static func ejectAfterInstall(find: @escaping @Sendable () -> [URL] = { volumes() },
                                  eject: @escaping @Sendable (URL) throws -> Void = { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) }) async {
        await Task.detached {
            for volume in find() { try? eject(volume) }
        }.value
    }
}
