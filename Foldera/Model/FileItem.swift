import Foundation
import UniformTypeIdentifiers

nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let displayName: String
    let isDirectory: Bool
    let isPackage: Bool
    let isVolume: Bool
    let isHidden: Bool
    let size: Int64?
    let dateModified: Date?
    let dateCreated: Date?
    let kind: String
    let contentType: UTType?

    var id: URL { url }

    /// Folders the explorer navigates into instead of opening (packages such as .app open like files).
    var isNavigable: Bool { isDirectory && !isPackage }

    @MainActor var localizedKind: String {
        isNavigable ? L10n.text("Folder") : L10n.text(kind)
    }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey, .isVolumeKey, .isHiddenKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey,
        .localizedTypeDescriptionKey, .contentTypeKey,
    ]

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        let name = values?.name ?? url.lastPathComponent
        self.url = url.normalizedFileURL
        self.name = name
        self.displayName = values?.localizedName ?? name
        self.isDirectory = values?.isDirectory ?? false
        self.isPackage = values?.isPackage ?? false
        self.isVolume = values?.isVolume ?? false
        self.isHidden = values?.isHidden ?? name.hasPrefix(".")
        self.size = isDirectory && !isPackage ? nil : values?.fileSize.map(Int64.init)
        self.dateModified = values?.contentModificationDate
        self.dateCreated = values?.creationDate
        self.kind = values?.localizedTypeDescription ?? (isDirectory ? "Folder" : "File")
        self.contentType = values?.contentType
    }

    /// Name shown in the list; extensions are hidden like Windows unless the user turns them on.
    func title(showExtensions: Bool) -> String {
        if showExtensions || isNavigable { return name }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }
}

nonisolated extension URL {
    /// Standardized file URL without a trailing slash, so URLs for the same item always compare equal
    /// (directory listings add a trailing slash to folders; URLs we build do not).
    var normalizedFileURL: URL {
        if isRemote, let endpoint = remoteEndpoint { return endpoint.url(path: remotePath) }
        guard isFileURL else { return self } // e.g. the "This Mac" page
        return URL(fileURLWithPath: standardizedFileURL.path, isDirectory: false)
    }
}

nonisolated enum DirectoryLoader {
    static func load(_ directory: URL) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: []
            )
            return urls.map(FileItem.init(url:))
        }.value
    }
}
