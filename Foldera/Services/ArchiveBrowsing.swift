import Foundation
import UniformTypeIdentifiers

/// One item inside an archive, as 7-Zip lists it.
nonisolated struct ArchiveEntry: Hashable, Sendable {
    /// The name 7-Zip uses for it, passed back when extracting.
    let rawPath: String
    /// Folders separated by "/", without a leading "/" (the archive's top level is "").
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?

    var name: String { ArchiveLocation.name(of: path) }
    var parent: String { ArchiveLocation.parent(of: path) }

    /// Drops "/", "." and empty parts. Nil for names that climb out with "..": 7-Zip won't extract
    /// them where they say, so they can't be shown in a folder either.
    static func cleanPath(_ raw: String) -> String? {
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}

/// A folder inside an archive, as a `foldera-archive:` address: the archive's path, with the folder
/// inside it as the fragment ("foldera-archive:/Users/me/Wine.7z#Wine/Notes").
nonisolated struct ArchiveLocation: Hashable, Sendable {
    static let scheme = "foldera-archive"

    /// The archive file.
    let archive: URL
    /// The folder inside it, "" for its top level.
    let path: String

    init(archive: URL, path: String = "") {
        self.archive = URL(fileURLWithPath: archive.standardizedFileURL.path, isDirectory: false)
        self.path = ArchiveEntry.cleanPath(path) ?? ""
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.path.hasPrefix("/") else { return nil }
        self.init(archive: URL(fileURLWithPath: components.path), path: components.fragment ?? "")
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.path = archive.path
        if !path.isEmpty { components.fragment = path }
        // Built from a file path and a cleaned folder path, so this can't fail.
        return components.url!
    }

    /// A typed path that goes through an archive file, like "/Users/me/Wine.7z/Wine/Notes": the archive is
    /// the deepest part that exists on disk. Nil when no archive Foldera can browse is on the way.
    static func resolve(_ path: String) -> ArchiveLocation? {
        var prefix = URL(fileURLWithPath: path).standardizedFileURL
        var inside: [String] = []
        while prefix.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: prefix.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue, Archives.isBrowsable(prefix) else { return nil }
                return ArchiveLocation(archive: prefix, path: inside.reversed().joined(separator: "/"))
            }
            inside.append(prefix.lastPathComponent)
            prefix = prefix.deletingLastPathComponent()
        }
        return nil
    }

    var isRoot: Bool { path.isEmpty }
    /// The folder's name; the archive's own name at its top level.
    var name: String { isRoot ? archive.lastPathComponent : Self.name(of: path) }
    /// The enclosing folder inside the archive; nil at the top level, whose parent is the archive's folder.
    var parent: ArchiveLocation? { isRoot ? nil : ArchiveLocation(archive: archive, path: Self.parent(of: path)) }

    func child(_ entry: ArchiveEntry) -> ArchiveLocation { ArchiveLocation(archive: archive, path: entry.path) }

    /// Every level from the archive's top level down to this one.
    var ancestors: [ArchiveLocation] {
        var result = [ArchiveLocation(archive: archive)]
        var current = ""
        for part in path.split(separator: "/") {
            current = current.isEmpty ? String(part) : current + "/" + part
            result.append(ArchiveLocation(archive: archive, path: current))
        }
        return result
    }

    /// "Wine.7z › Wine › Notes" style text for alerts and Copy as path: the archive's path, then the inside.
    var displayPath: String { isRoot ? archive.path : archive.path + "/" + path }

    static func name(of path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

nonisolated extension URL {
    /// A folder or item inside an archive, browsed without extracting it.
    var isInArchive: Bool { scheme?.lowercased() == ArchiveLocation.scheme }
    var archiveLocation: ArchiveLocation? { ArchiveLocation(url: self) }
}

/// Archive listings for browsing, read once and kept while the archive file is unchanged, and the
/// passwords typed for them this session (in memory only).
nonisolated final class ArchiveCatalog: @unchecked Sendable {
    static let shared = ArchiveCatalog()

    private struct Listing {
        let signature: Signature
        /// Every item, including folders that only appear as part of other items' paths, by folder.
        let children: [String: [ArchiveEntry]]
        let entries: [String: ArchiveEntry]
    }

    private struct Signature: Equatable {
        let size: Int
        let modified: Date?

        init(_ archive: URL) throws {
            let values = try archive.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size = values.fileSize ?? 0
            modified = values.contentModificationDate
        }
    }

    private let lock = NSLock()
    private var listings: [String: Listing] = [:]
    private var passwords: [String: String] = [:]

    func password(for archive: URL) -> String? { lock.withLock { passwords[archive.standardizedFileURL.path] } }

    func setPassword(_ password: String?, for archive: URL) {
        lock.withLock { passwords[archive.standardizedFileURL.path] = password }
    }

    /// The items directly in `location`. Throws `Archives.PasswordRequired` when the names are encrypted
    /// and no (right) password is known yet.
    func children(of location: ArchiveLocation) throws -> [ArchiveEntry] {
        let listing = try self.listing(for: location.archive)
        guard location.isRoot || listing.entries[location.path]?.isDirectory == true else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: location.displayPath])
        }
        return listing.children[location.path] ?? []
    }

    /// Bytes unpacked when extracting `paths` (with everything in the folders among them), or the whole
    /// archive when `paths` is empty. Nil when the listing can't be read, e.g. without its password.
    func unpackedSize(of paths: [String], in archive: URL) -> Int64? {
        guard let listing = try? listing(for: archive) else { return nil }
        let files = listing.entries.values.filter { !$0.isDirectory }
        let chosen = paths.isEmpty ? files : files.filter { file in
            paths.contains { file.path == $0 || file.path.hasPrefix($0 + "/") }
        }
        return chosen.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// The listed item at `path`, if the archive has been read.
    func entry(_ path: String, in archive: URL) -> ArchiveEntry? {
        lock.withLock { listings[archive.standardizedFileURL.path]?.entries[path] }
    }

    private func listing(for archive: URL) throws -> Listing {
        let key = archive.standardizedFileURL.path
        let signature = try Signature(archive)
        if let cached = lock.withLock({ listings[key] }), cached.signature == signature { return cached }
        let listing = Self.index(try Archives.list(archive, password: password(for: archive)), signature: signature)
        lock.withLock { listings[key] = listing }
        return listing
    }

    private static func index(_ listed: [ArchiveEntry], signature: Signature) -> Listing {
        var entries: [String: ArchiveEntry] = [:]
        for entry in listed where entries[entry.path] == nil || entry.isDirectory {
            entries[entry.path] = entry
        }
        // Zips often leave folders out and only list the files in them.
        for entry in listed {
            var parent = entry.parent
            while !parent.isEmpty, entries[parent] == nil {
                entries[parent] = ArchiveEntry(rawPath: parent, path: parent, isDirectory: true, isSymlink: false, size: nil, modified: nil)
                parent = ArchiveLocation.parent(of: parent)
            }
        }
        var children: [String: [ArchiveEntry]] = [:]
        for entry in entries.values { children[entry.parent, default: []].append(entry) }
        return Listing(signature: signature, children: children, entries: entries)
    }
}

nonisolated extension FileItem {
    init(archiveEntry entry: ArchiveEntry, in archive: URL) {
        let name = entry.name
        let type = entry.isDirectory ? UTType.folder : UTType(filenameExtension: (name as NSString).pathExtension)
        url = ArchiveLocation(archive: archive, path: entry.path).url
        self.name = name
        isDirectory = entry.isDirectory
        isPackage = false
        isVolume = false
        isHidden = name.hasPrefix(".")
        size = entry.size
        dateModified = entry.modified
        dateCreated = nil
        kind = entry.isDirectory ? "Folder" : TypeNames.name(of: type)
        contentType = type
    }
}

/// Listing archive folders for `BrowserTab`, and taking items out of archives to open or copy them.
nonisolated enum ArchiveDirectory {
    /// Where items are taken out to open, copy or preview them; macOS clears the temporary folder over time.
    static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Foldera Archive Items", isDirectory: true)

    static func load(_ url: URL, catalog: ArchiveCatalog = .shared) async throws -> [FileItem] {
        guard let location = url.archiveLocation else { throw CocoaError(.fileReadInvalidFileName) }
        return try await Task.detached(priority: .userInitiated) {
            try catalog.children(of: location).map { FileItem(archiveEntry: $0, in: location.archive) }
        }.value
    }

    /// Extracts items from one archive into a new temporary folder and returns where each one landed.
    /// Throws `Archives.PasswordRequired` until `catalog` knows the right password.
    static func extractToTemporaryFolder(_ urls: [URL], catalog: ArchiveCatalog = .shared,
                                         progress: TransferProgress? = nil, totalBytes: Int64 = 0) throws -> [URL] {
        let locations = urls.compactMap(\.archiveLocation)
        guard let archive = locations.first?.archive else { return [] }
        let folder = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try extract(locations, from: archive, into: folder, catalog: catalog, progress: progress, totalBytes: totalBytes)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return locations.map { folder.appendingPathComponent($0.path) }
    }

    /// Extracts items (with everything in the folders among them) into `folder`, keeping their paths inside the archive.
    /// A folder the archive only implies, with no entry of its own, still brings the items under it.
    static func extract(_ locations: [ArchiveLocation], from archive: URL, into folder: URL, catalog: ArchiveCatalog = .shared,
                        progress: TransferProgress? = nil, totalBytes: Int64 = 0) throws {
        let names = locations.map { catalog.entry($0.path, in: archive)?.rawPath ?? $0.path }
        try Archives.extract(archive, into: folder, password: catalog.password(for: archive), entries: names,
                             progress: progress, totalBytes: totalBytes)
    }

    /// Extracts items into `folder` through a staging folder, keeping both when names clash. Returns what was added.
    static func extractKeepingBoth(_ locations: [ArchiveLocation], from archive: URL, into folder: URL, catalog: ArchiveCatalog = .shared,
                                   progress: TransferProgress? = nil, totalBytes: Int64 = 0) throws -> [URL] {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fm.removeItem(at: staging) }
        try extract(locations, from: archive, into: staging, catalog: catalog, progress: progress, totalBytes: totalBytes)
        var created: [URL] = []
        for location in locations {
            let destination = FileOperations.uniqueURL(named: location.name, in: folder)
            try fm.moveItem(at: staging.appendingPathComponent(location.path), to: destination)
            created.append(destination)
        }
        return created
    }
}
