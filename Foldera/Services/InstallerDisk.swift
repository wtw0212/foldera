import AppKit
import CryptoKit
import Darwin

/// Only the marked release image belonging to the installed copy is eligible for automatic eject.
nonisolated enum InstallerDisk {
    private struct Receipt: Decodable, Equatable {
        let format: Int
        let installerID: UUID
        let bundleIdentifier: String
        let version: String
        let build: String
        let executableSHA256: String
    }

    static func volumes(app: URL = Bundle.main.bundleURL, applications: [URL]? = nil, images: [URL]? = nil) -> [URL] {
        let fm = FileManager.default
        let installed = app.resolvingSymlinksInPath().standardizedFileURL
        let roots = applications ?? fm.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        guard roots.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == installed.deletingLastPathComponent() }),
              let release = receipt(for: installed) else { return [] }
        let appVolume = try? installed.resourceValues(forKeys: [.volumeURLKey]).volume?.resolvingSymlinksInPath()
        let candidates = Set((images ?? readOnlyImages()).map { $0.resolvingSymlinksInPath().standardizedFileURL }).filter { volume in
            guard volume != appVolume,
                  let values = try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsEjectableKey, .volumeLocalizedNameKey]),
                  values.volumeIsReadOnly == true, values.volumeIsEjectable == true,
                  values.volumeLocalizedName == "Foldera \(release.version)",
                  let names = try? fm.contentsOfDirectory(atPath: volume.path),
                  Set(names).isSubset(of: ["Foldera.app", "Applications", ".foldera-installer.plist", ".DS_Store", ".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems"]),
                  (try? fm.destinationOfSymbolicLink(atPath: volume.appendingPathComponent("Applications").path)) == "/Applications",
                  let data = regularData(volume.appendingPathComponent(".foldera-installer.plist")),
                  let marker = try? PropertyListDecoder().decode(Receipt.self, from: data), marker == release,
                  receipt(for: volume.appendingPathComponent("Foldera.app")) == release
            else { return false }
            return true
        }
        // Multiple identical images leave the installation source ambiguous.
        return candidates.count == 1 ? Array(candidates) : []
    }

    /// Normal eject only: a busy image remains mounted, with the existing manual Eject action available.
    static func ejectAfterInstall(find: @escaping @Sendable () -> [URL] = { volumes() },
                                  eject: @escaping @Sendable (URL) throws -> Void = { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) }) async {
        await Task.detached {
            for volume in find() { try? eject(volume) }
        }.value
    }

    /// hdiutil supplies the backing-image relationship; removable physical disks never enter this list.
    static func readOnlyImages(from data: Data) -> [URL] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.flatMap { image -> [URL] in
            guard image["writeable"] as? Bool == false, image["owner-uid"] as? Int == Int(getuid()),
                  let path = image["image-path"] as? String, path.hasPrefix("/"),
                  URL(fileURLWithPath: path).pathExtension.lowercased() == "dmg",
                  let entities = image["system-entities"] as? [[String: Any]] else { return [] }
            return entities.compactMap { entity in
                guard let mount = entity["mount-point"] as? String, mount.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: mount, isDirectory: true)
            }
        }
    }

    private static func readOnlyImages() -> [URL] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? readOnlyImages(from: data) : []
    }

    private static func receipt(for app: URL) -> Receipt? {
        var info = stat()
        guard lstat(app.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let data = regularData(app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "com.wtw0212.foldera",
              plist["CFBundleExecutable"] as? String == "Foldera",
              let rawID = plist["FolderaInstallerID"] as? String, let id = UUID(uuidString: rawID),
              let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty,
              let build = plist["CFBundleVersion"] as? String, !build.isEmpty else { return nil }
        let executable = app.appendingPathComponent("Contents/MacOS/Foldera")
        guard FileOperations.contains(app, executable.deletingLastPathComponent()),
              lstat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        } catch { return nil }
        return Receipt(format: 1, installerID: id, bundleIdentifier: "com.wtw0212.foldera", version: version, build: build,
                       executableSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func regularData(_ url: URL) -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 65_536 else { return nil }
        return try? Data(contentsOf: url)
    }
}
