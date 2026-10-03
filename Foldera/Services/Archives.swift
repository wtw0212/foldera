import Foundation

/// Zip, 7z and unzip for the context menu.
///
/// Extraction uses the bundled 7-Zip (`7zz`, see ThirdParty/7-Zip), which reads zip, 7z, rar (incl. RAR5),
/// split archives, iso, cab and more, including password-protected ones. tar-based archives
/// (tar.gz, tgz…) go through the system's bsdtar instead, which unpacks both layers in one step.
/// Both refuse absolute paths and ".." entries. Nothing is ever extracted over existing items:
/// archives unpack into a fresh folder, or a staging folder whose contents then move in under unique names.
nonisolated enum Archives {
    /// Longest first, so "x.tar.gz" matches "tar.gz" rather than "gz".
    private static let suffixes = [
        "tar.gz", "tar.bz2", "tar.xz", "7z.001", "zip.001",
        "zip", "7z", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz", "iso", "cab", "wim", "lzh", "arj",
    ]
    private static let tarSuffixes: Set<String> = ["tar.gz", "tar.bz2", "tar.xz", "tar", "tgz", "tbz", "tbz2", "txz"]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The archive is encrypted: ask for a password (again, when `wasWrong`) and retry.
    struct PasswordRequired: Error {
        let archive: URL
        let wasWrong: Bool
    }

    enum Format { case zip, sevenZip }

    /// The bundled 7-Zip console program, in Foldera.app/Contents/MacOS.
    static var sevenZip: URL? { Bundle.main.url(forAuxiliaryExecutable: "7zz") }

    static var canCreate7z: Bool { sevenZip != nil }

    /// True for archives Foldera can extract. Later parts of split archives (".002", ".part2.rar")
    /// are left out: extracting the first part reads the rest.
    static func isArchive(_ url: URL) -> Bool {
        suffix(of: url) != nil && !isLaterVolume(url)
    }

    private static func isLaterVolume(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if let range = name.range(of: #"\.part0*(\d+)\.rar$"#, options: .regularExpression) {
            let digits = name[range].filter(\.isNumber)
            return Int(digits) != 1
        }
        if let range = name.range(of: #"\.(7z|zip)\.\d{3}$"#, options: .regularExpression) {
            return !name[range].hasSuffix(".001")
        }
        return false
    }

    /// "photos.tar.gz" → "photos", "movie.part1.rar" → "movie".
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        guard let suffix = suffix(of: url) else { return (name as NSString).deletingPathExtension }
        var base = String(name.dropLast(suffix.count + 1))
        if let part = base.range(of: #"\.part\d+$"#, options: [.regularExpression, .caseInsensitive]) {
            base.removeSubrange(part)
        }
        return base.isEmpty ? name : base
    }

    private static func suffix(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return suffixes.first { name.hasSuffix("." + $0) }
    }

    // MARK: Extract

    /// Extracts into a new folder named after the archive, next to it. Returns that folder.
    static func extractToFolder(_ archive: URL, password: String? = nil) throws -> URL {
        let folder = FileOperations.uniqueURL(named: baseName(of: archive), in: archive.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try extract(archive, into: folder, password: password)
        } catch {
            try? FileManager.default.removeItem(at: folder) // ours, created above
            throw error
        }
        return folder
    }

    /// Extracts the archive's contents into `folder` itself, keeping both when names clash.
    /// Returns the items that were added.
    static func extractHere(_ archive: URL, into folder: URL, password: String? = nil) throws -> [URL] {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fm.removeItem(at: staging) }
        try extract(archive, into: staging, password: password)
        var added: [URL] = []
        for item in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            let destination = FileOperations.uniqueURL(named: item.lastPathComponent, in: folder)
            try fm.moveItem(at: item, to: destination)
            added.append(destination)
        }
        return added
    }

    static func extract(_ archive: URL, into directory: URL, password: String? = nil) throws {
        let useTar = suffix(of: archive).map(tarSuffixes.contains) ?? false
        guard !useTar, let sevenZip else {
            // __MACOSX holds Finder metadata copies that only clutter the result.
            try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-x", "-f", archive.path, "-C", directory.path, "--exclude", "__MACOSX"])
            return
        }
        do {
            // The password goes in on stdin, so it never shows up in the process list. Without one,
            // 7-Zip reads an empty line and reports a wrong password for encrypted archives.
            try run(sevenZip, ["x", "-y", "-bso0", "-bsp0", "-xr!__MACOSX", "-o" + directory.path, "--", archive.path],
                    input: (password ?? "") + "\n")
        } catch let failure as Failure where failure.message.localizedCaseInsensitiveContains("wrong password")
            || failure.message.localizedCaseInsensitiveContains("encrypted") {
            throw PasswordRequired(archive: archive, wasWrong: password != nil)
        }
    }

    // MARK: Compress

    /// Compresses `items` like Finder: one item becomes "<name>.zip" (or .7z), several become "Archive.zip".
    /// The archive goes next to the items, or into `fallbackFolder` when they're in different folders.
    static func compress(_ items: [URL], format: Format = .zip, fallbackFolder: URL) throws -> URL {
        guard let first = items.first else { throw Failure(message: "Nothing to compress.") }
        let parent = first.deletingLastPathComponent()
        let sameParent = items.allSatisfy { $0.deletingLastPathComponent().path == parent.path }
        let folder = sameParent ? parent : fallbackFolder
        let ext = format == .zip ? "zip" : "7z"
        let archive = FileOperations.uniqueURL(named: items.count == 1 ? "\(first.lastPathComponent).\(ext)" : "Archive.\(ext)", in: folder)
        do {
            switch format {
            case .sevenZip:
                guard let sevenZip else { throw Failure(message: "7-Zip isn’t available.") }
                // Given full paths, 7-Zip stores each item under its own name (no parent folders).
                try run(sevenZip, ["a", "-t7z", "-mx=5", "-y", "-bso0", "-bsp0", "-xr!.DS_Store", "--", archive.path] + items.map(\.path))
            case .zip where items.count == 1:
                // ditto keeps macOS metadata (resource forks, extended attributes) the way Finder does.
                // For a file, --keepParent includes its containing directory instead of just the file.
                var arguments = ["-c", "-k", "--sequesterRsrc"]
                if try first.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    arguments.append("--keepParent")
                }
                try run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments + [first.path, archive.path])
            case .zip where sameParent:
                try run(URL(fileURLWithPath: "/usr/bin/zip"), ["-r", "-y", "-q", archive.path] + items.map(\.lastPathComponent) + ["-x", "*.DS_Store"], in: parent)
            case .zip:
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
                try run(URL(fileURLWithPath: "/usr/bin/zip"), ["-r", "-q", archive.path] + names + ["-x", "*.DS_Store"], in: staging)
            }
        } catch {
            try? FileManager.default.removeItem(at: archive) // a partial archive under our new, unique name
            throw error
        }
        return archive
    }

    // MARK: Process

    private static func run(_ tool: URL, _ arguments: [String], in directory: URL? = nil, input: String? = nil) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "tar: ", with: "")
            throw Failure(message: message?.isEmpty == false ? message! : "\(tool.lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }
}
