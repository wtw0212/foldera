import Foundation

/// Zip and unzip for the context menu. Extraction uses the system's bsdtar (libarchive), which reads
/// zip, tar (gz/bz2/xz), 7z and rar, and refuses absolute paths and ".." entries by default.
/// Nothing is ever extracted over existing items: archives unpack into a fresh folder or a staging
/// folder whose contents are then moved in under unique names.
nonisolated enum Archives {
    /// Longest first, so "x.tar.gz" matches "tar.gz" rather than "gz".
    private static let suffixes = ["tar.gz", "tar.bz2", "tar.xz", "zip", "tar", "tgz", "tbz", "tbz2", "txz", "7z", "rar"]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func isArchive(_ url: URL) -> Bool { suffix(of: url) != nil }

    /// "photos.tar.gz" → "photos".
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        guard let suffix = suffix(of: url) else { return (name as NSString).deletingPathExtension }
        let base = String(name.dropLast(suffix.count + 1))
        return base.isEmpty ? name : base
    }

    private static func suffix(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return suffixes.first { name.hasSuffix("." + $0) }
    }

    /// Extracts into a new folder named after the archive, next to it. Returns that folder.
    static func extractToFolder(_ archive: URL) throws -> URL {
        let folder = FileOperations.uniqueURL(named: baseName(of: archive), in: archive.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try extract(archive, into: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder) // ours, created above
            throw error
        }
        return folder
    }

    /// Extracts the archive's contents into `folder` itself, keeping both when names clash.
    /// Returns the items that were added.
    static func extractHere(_ archive: URL, into folder: URL) throws -> [URL] {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fm.removeItem(at: staging) }
        try extract(archive, into: staging)
        var added: [URL] = []
        for item in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            let destination = FileOperations.uniqueURL(named: item.lastPathComponent, in: folder)
            try fm.moveItem(at: item, to: destination)
            added.append(destination)
        }
        return added
    }

    static func extract(_ archive: URL, into directory: URL) throws {
        // __MACOSX holds Finder metadata copies that only clutter the result.
        try run("/usr/bin/tar", ["-x", "-f", archive.path, "-C", directory.path, "--exclude", "__MACOSX"], in: nil)
    }

    /// Zips `items` like Finder's Compress: one item becomes "<name>.zip", several become "Archive.zip".
    /// The archive goes next to the items, or into `fallbackFolder` when they're in different folders.
    static func compress(_ items: [URL], fallbackFolder: URL) throws -> URL {
        guard let first = items.first else { throw Failure(message: "Nothing to compress.") }
        let parent = first.deletingLastPathComponent()
        let sameParent = items.allSatisfy { $0.deletingLastPathComponent().path == parent.path }
        let folder = sameParent ? parent : fallbackFolder
        let zip = FileOperations.uniqueURL(named: items.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip", in: folder)
        do {
            if items.count == 1 {
                // ditto keeps macOS metadata (resource forks, extended attributes) the way Finder does.
                try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, zip.path], in: nil)
            } else if sameParent {
                try run("/usr/bin/zip", ["-r", "-y", "-q", zip.path] + items.map(\.lastPathComponent) + ["-x", "*.DS_Store"], in: parent)
            } else {
                // Search results from several folders: store each item under its own name.
                let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                var names: [String] = []
                for item in items {
                    let link = FileOperations.uniqueURL(named: item.lastPathComponent, in: staging)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item)
                    names.append(link.lastPathComponent)
                }
                // Without -y, zip follows the links and stores the real files.
                try run("/usr/bin/zip", ["-r", "-q", zip.path] + names + ["-x", "*.DS_Store"], in: staging)
            }
        } catch {
            try? FileManager.default.removeItem(at: zip) // a partial archive under our new, unique name
            throw error
        }
        return zip
    }

    private static func run(_ tool: String, _ arguments: [String], in directory: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice // a password prompt fails instead of hanging
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "tar: ", with: "")
            throw Failure(message: message?.isEmpty == false ? message! : "\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }
}
