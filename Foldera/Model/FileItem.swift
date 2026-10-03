import Foundation
import UniformTypeIdentifiers

nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
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

    /// Only what the list shows. The type's name comes from `contentType` (see `TypeNames`): asking each
    /// file for its localized type description, or for a localized name, is the slowest part of a listing.
    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isVolumeKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: Self.resourceKeySet)
        let name = values?.name ?? url.lastPathComponent
        self.url = url.normalizedFileURL
        self.name = name
        self.isDirectory = values?.isDirectory ?? false
        self.isPackage = values?.isPackage ?? false
        self.isVolume = values?.isVolume ?? false
        self.isHidden = values?.isHidden ?? name.hasPrefix(".")
        self.size = isDirectory && !isPackage ? nil : values?.fileSize.map(Int64.init)
        self.dateModified = values?.contentModificationDate
        self.dateCreated = values?.creationDate
        self.contentType = values?.contentType
        self.kind = isDirectory && !isPackage ? "Folder" : TypeNames.name(of: contentType)
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

/// Localized type names ("PNG image", "Swift Source"), looked up once per type and shared by every item,
/// which saves both the per-file lookup and a copy of the string per file.
nonisolated enum TypeNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String: String] = [:]

    static func name(of type: UTType?) -> String {
        guard let type else { return "File" }
        if let cached = lock.withLock({ names[type.identifier] }) { return cached }
        let name = type.localizedDescription ?? "File"
        lock.withLock { names[type.identifier] = name }
        return name
    }
}

nonisolated enum DirectoryLoader {
    /// Folders up to this size are read on one thread; larger ones are split across cores.
    static let parallelThreshold = 512

    static func load(_ directory: URL) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: []
            )
            return items(for: urls)
        }.value
    }

    static func items(for urls: [URL]) -> [FileItem] {
        guard urls.count > parallelThreshold else { return urls.map(FileItem.init(url:)) }
        let chunks = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        let chunkSize = (urls.count + chunks - 1) / chunks
        var parts = [[FileItem]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let range = (chunk * chunkSize)..<min(urls.count, (chunk + 1) * chunkSize)
                buffer[chunk] = range.isEmpty ? [] : urls[range].map(FileItem.init(url:))
            }
        }
        return parts.flatMap { $0 }
    }
}
