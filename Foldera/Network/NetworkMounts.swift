import AppKit
import NetFS

/// Connects to file servers (SMB, AFP, NFS, WebDAV) with macOS's own mounting and sign-in, like
/// Finder's Connect to Server.
enum NetworkMounts {
    /// Schemes macOS can mount. In the address bar http(s) still opens the browser; Connect to Server mounts it as WebDAV.
    static let schemes: Set<String> = ["smb", "cifs", "afp", "nfs", "webdav", "http", "https"]

    static func canMount(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return schemes.contains(scheme) && !(url.host() ?? "").isEmpty
    }

    /// Mounts `url` (asking for a user name and password if needed) and returns where it's mounted.
    static func mount(_ url: URL) async throws -> URL {
        let target = webDAVURL(url)
        return try await withCheckedThrowingContinuation { continuation in
            let options = NSMutableDictionary()
            options[kNAUIOptionKey] = kNAUIOptionAllowUI
            var request: AsyncRequestID?
            let status = NetFSMountURLAsync(target as CFURL, nil, nil, nil, options, nil, &request, .main) { status, _, mountPoints in
                let paths = mountPoints as? [String] ?? []
                if status == 0, let path = paths.first {
                    continuation.resume(returning: URL(fileURLWithPath: path))
                } else if status == EEXIST, let mounted = mountedVolume(for: target) {
                    continuation.resume(returning: mounted)
                } else {
                    continuation.resume(throwing: error(status, url: url))
                }
            }
            if status != 0 { continuation.resume(throwing: error(status, url: url)) }
        }
    }

    /// webdav:// isn't a real scheme; macOS mounts WebDAV from http(s) URLs.
    static func webDAVURL(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "webdav", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// An already-mounted volume for the same server and share.
    static func mountedVolume(for url: URL) -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.first { volume in
            guard let remount = (try? volume.resourceValues(forKeys: Set(keys)))?.volumeURLForRemounting else { return false }
            return remount.host()?.lowercased() == url.host()?.lowercased()
                && remount.path(percentEncoded: false).trimmingCharacters(in: ["/"]) == url.path(percentEncoded: false).trimmingCharacters(in: ["/"])
        }
    }

    private static func error(_ status: Int32, url: URL) -> Error {
        // userCanceledErr (-128) and ECANCELED both mean the sign-in sheet was cancelled.
        if status == -128 || status == ECANCELED { return CancellationError() }
        let reason = status > 0 ? String(cString: strerror(status)) : "error \(status)"
        return RemoteError.failed(L10n.format("Foldera couldn’t connect to %@.", url.host() ?? url.absoluteString) + " (\(reason))")
    }
}
