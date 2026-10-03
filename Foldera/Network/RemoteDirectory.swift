import Foundation
import UniformTypeIdentifiers

/// Listing and naming sftp:// folders for `BrowserTab`.
enum RemoteDirectory {
    static func load(_ url: URL, connections: RemoteConnections = .shared) async throws -> [FileItem] {
        guard let endpoint = url.remoteEndpoint else { throw RemoteError.failed(L10n.text("This address is missing a user name.")) }
        do {
            let entries = try await connections.perform(endpoint) { try await $0.list(url.remotePath) }
            return entries.map { FileItem(remote: $0, endpoint: endpoint) }
        } catch is CancellationError {
            // The sign-in prompt was cancelled.
            throw RemoteError.notConnected(endpoint.displayName)
        }
    }

    /// A server's root shows the site name (or user@host); other folders their own name.
    static func name(of url: URL, sites: SFTPSites = .shared) -> String {
        guard let endpoint = url.remoteEndpoint else { return url.absoluteString }
        if url.remotePath == "/" { return sites.site(for: endpoint)?.title ?? endpoint.displayName }
        return RemotePath.name(of: url.remotePath)
    }
}

nonisolated extension FileItem {
    init(remote entry: RemoteEntry, endpoint: RemoteEndpoint) {
        let name = entry.name
        let type = entry.isDirectory ? UTType.folder : UTType(filenameExtension: (name as NSString).pathExtension)
        url = endpoint.url(path: entry.path)
        self.name = name
        isDirectory = entry.isDirectory
        isPackage = false
        isVolume = false
        isHidden = name.hasPrefix(".")
        size = entry.isDirectory ? nil : entry.size
        dateModified = entry.modified
        dateCreated = nil
        kind = entry.isDirectory ? "Folder" : TypeNames.name(of: type)
        contentType = type
    }
}
