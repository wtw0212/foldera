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

    enum Format: String, CaseIterable, Sendable { case zip, sevenZip

        var fileExtension: String { self == .zip ? "zip" : "7z" }
    }

    /// 7-Zip's compression levels (-mx).
    enum Level: Int, CaseIterable, Sendable { case store = 0, fastest = 1, normal = 5, maximum = 7, ultra = 9 }

    /// How a password-protected zip is encrypted: AES-256 is strong; ZipCrypto is weak but opens almost anywhere.
    enum ZipEncryption: String, CaseIterable, Sendable { case aes256, zipCrypto }

    /// The "Compress to…" choices. The defaults are what the plain Compress commands do.
    struct Options: Sendable {
        var format: Format = .zip
        var level: Level = .normal
        /// Nil or empty: no encryption.
        var password: String?
        var zipEncryption: ZipEncryption = .aes256
        /// 7z only: also hides the names of the items inside until the password is given.
        var encryptNames = true

        var hasPassword: Bool { password?.isEmpty == false }

        /// Zip passwords are bytes without a declared encoding, so 7-Zip only takes printable ASCII for them.
        static func isValidPassword(_ password: String, for format: Format) -> Bool {
            format == .sevenZip || password.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
        }
    }

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

    /// Extracts into a new folder named after the archive, in `parent` (next to the archive by default). Returns that folder.
    static func extractToFolder(_ archive: URL, in parent: URL? = nil, password: String? = nil) throws -> URL {
        let folder = FileOperations.uniqueURL(named: baseName(of: archive), in: parent ?? archive.deletingLastPathComponent())
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

    /// Where Finder-style Compress puts the archive: "<name>.zip" (or .7z) for one item, "Archive.zip" for several,
    /// next to the items, or in `fallbackFolder` when they're in different folders.
    static func archiveURL(for items: [URL], format: Format = .zip, fallbackFolder: URL) -> URL? {
        guard let first = items.first else { return nil }
        let parent = first.deletingLastPathComponent()
        let sameParent = items.allSatisfy { $0.deletingLastPathComponent().path == parent.path }
        return FileOperations.uniqueURL(named: "\(defaultName(for: items)).\(format.fileExtension)", in: sameParent ? parent : fallbackFolder)
    }

    /// The archive's name without its extension: the item's own name for one item, "Archive" for several.
    static func defaultName(for items: [URL]) -> String {
        items.count == 1 ? items[0].lastPathComponent : "Archive"
    }

    /// "Report" → "Report.zip". A name that already ends in the format's extension keeps it as typed.
    static func fileName(_ name: String, format: Format) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.lowercased().hasSuffix("." + format.fileExtension) ? name : "\(name).\(format.fileExtension)"
    }

    /// Compresses `items` like Finder. See `archiveURL(for:format:fallbackFolder:)` for where the archive goes.
    static func compress(_ items: [URL], format: Format = .zip, fallbackFolder: URL, progress: TransferProgress? = nil) throws -> URL {
        guard let archive = archiveURL(for: items, format: format, fallbackFolder: fallbackFolder) else { throw Failure(message: "Nothing to compress.") }
        try compress(items, format: format, to: archive, progress: progress)
        return archive
    }

    /// Compresses `items` into `archive`, which must not exist. `progress` gets bytes read from the items.
    /// Symbolic links are stored as links and never followed, so an archive holds only what was selected.
    static func compress(_ items: [URL], format: Format = .zip, to archive: URL, progress: TransferProgress? = nil) throws {
        try compress(items, options: Options(format: format), to: archive, progress: progress)
    }

    /// Compresses `items` into `archive` with the "Compress to…" choices; see `compress(_:format:to:progress:)`.
    static func compress(_ items: [URL], options: Options, to archive: URL, progress: TransferProgress? = nil) throws {
        if options.hasPassword, !Options.isValidPassword(options.password!, for: options.format) {
            throw Failure(message: L10n.text("ZIP passwords can only use English letters, digits and symbols.", language: .saved))
        }
        guard let first = items.first else { throw Failure(message: "Nothing to compress.") }
        // An archive inside a folder it compresses would end up holding part of itself.
        for item in items { try FileOperations.rejectCopyIntoSource(item, to: archive) }
        if progress?.isCancelled == true { throw CopyEngine.Cancelled() }
        let parent = first.deletingLastPathComponent()
        let sameParent = items.allSatisfy { $0.deletingLastPathComponent().path == parent.path }
        let meter = progress.map { CompressionMeter(progress: $0, archive: archive, total: items.reduce(0) { $0 + CopyEngine.size(of: $1) }) }
        do {
            if sameParent {
                try compress(items.map(\.lastPathComponent), in: parent, options: options, to: archive, meter: meter)
            } else {
                // Search results from several folders: each item is copied (cloned on APFS, links kept as links)
                // into a staging folder under its own unique name, and archived from there.
                let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: archive.deletingLastPathComponent(), create: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                var names: [String] = []
                for item in items {
                    let copy = FileOperations.uniqueURL(named: item.lastPathComponent, in: staging)
                    try CopyEngine.copy(item, to: copy, progress: TransferProgress(cancellationSource: progress), baseBytes: 0)
                    names.append(copy.lastPathComponent)
                }
                try compress(names, in: staging, options: options, to: archive, meter: meter)
            }
        } catch {
            try? FileManager.default.removeItem(at: archive) // a partial archive under our new, unique name
            throw error
        }
        meter?.complete() // 7-Zip skips its last percentages when it finishes quickly
    }

    /// Archives the items `names` in `directory`, each under its own name.
    private static func compress(_ names: [String], in directory: URL, options: Options, to archive: URL, meter: CompressionMeter?) throws {
        let items = names.map { directory.appendingPathComponent($0) }
        // A plain zip goes through ditto or zip, like Finder; anything else needs 7-Zip.
        let plainZip = options.format == .zip && options.level == .normal && !options.hasPassword
        if !plainZip {
            guard let sevenZip else { throw Failure(message: "7-Zip isn’t available.") }
            var arguments = ["a", options.format == .zip ? "-tzip" : "-t7z", "-mx=\(options.level.rawValue)"]
            if options.hasPassword {
                // A bare -p reads the password from stdin, so it never shows up in the process list.
                arguments.append("-p")
                switch options.format {
                case .zip: arguments.append(options.zipEncryption == .aes256 ? "-mem=AES256" : "-mem=ZipCrypto")
                case .sevenZip: if options.encryptNames { arguments.append("-mhe=on") }
                }
            }
            // Given full paths, 7-Zip stores each item under its own name (no parent folders). -snl keeps links.
            arguments += ["-snl", "-y", "-bso0", meter == nil ? "-bsp0" : "-bsp1", "-xr!.DS_Store", "--", archive.path]
            try run(sevenZip, arguments + items.map(\.path), input: options.hasPassword ? options.password! + "\n" : nil, meter: meter) { line in
                // "-bsp1" redraws "  42% 12 + name" in place.
                guard let match = line.firstMatch(of: #/^\s*(\d+)%/#), let percent = Int(match.1) else { return false }
                meter?.reached(percent: percent)
                return true
            }
        } else if items.count == 1 && !isSymbolicLink(items[0]) {
            // ditto keeps macOS metadata (resource forks, extended attributes) the way Finder does. It follows
            // a link given as its source, so a selected link goes to zip below; links inside a folder stay links.
            // For a file, --keepParent includes its containing directory instead of just the file.
            var arguments = ["-c", "-k", "--sequesterRsrc"]
            if try items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                arguments.append("--keepParent")
            }
            if meter != nil { arguments.append("-V") }
            try run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments + [items[0].path, archive.path], meter: meter) { line in
                // -V prints "copying file ./x ... " before and "1234 bytes for ./x" after each file.
                if let match = line.firstMatch(of: #/^(\d+) bytes for /#), let bytes = Int64(match.1) {
                    meter?.finished(bytes: bytes)
                    return true
                }
                return line.hasPrefix(">>> Copying ") || line.hasPrefix("copying file ")
            }
        } else {
            // -y stores links as links.
            // Relative operands start with ./ so names beginning with '-' cannot become zip options.
            try run(URL(fileURLWithPath: "/usr/bin/zip"), ["-r", "-y"] + (meter == nil ? ["-q"] : []) + [archive.path] + names.map { "./" + $0 } + ["-x", "*.DS_Store"],
                    in: directory, meter: meter) { zipLine($0, in: directory, meter: meter) }
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// zip prints "  adding: name (deflated 12%)" once a file is in the archive.
    private static func zipLine(_ line: String, in directory: URL, meter: CompressionMeter?) -> Bool {
        guard let start = line.range(of: "adding: "), let end = line.range(of: " (", options: .backwards), start.upperBound <= end.lowerBound else {
            return false
        }
        let name = String(line[start.upperBound..<end.lowerBound])
        let item = directory.appendingPathComponent(name)
        let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) // a link's own size, not its target's
        meter?.finished(bytes: values?.isDirectory == true ? 0 : Int64(values?.fileSize ?? 0))
        return true
    }

    /// Turns a compressor's output into byte progress. Between files it counts the archive's growth,
    /// up to what is left, so a single large file still moves the bar.
    private final class CompressionMeter: @unchecked Sendable {
        private let lock = NSLock()
        private let progress: TransferProgress
        private let archive: URL
        private let total: Int64
        private var completed: Int64 = 0
        private var archiveAtLastFile: Int64 = 0
        private var byPercent = false

        init(progress: TransferProgress, archive: URL, total: Int64) {
            self.progress = progress
            self.archive = archive
            self.total = total
            progress.setCurrentName(archive.lastPathComponent)
        }

        var isCancelled: Bool { progress.isCancelled }

        func finished(bytes: Int64) {
            let size = archiveSize
            lock.withLock {
                completed = min(total, completed + bytes)
                archiveAtLastFile = size
            }
            update()
        }

        func reached(percent: Int) {
            lock.withLock {
                byPercent = true
                completed = max(completed, total * Int64(min(100, percent)) / 100)
            }
            update()
        }

        func complete() {
            lock.withLock { completed = total; byPercent = true }
            update()
        }

        func update() {
            let size = archiveSize
            let value = lock.withLock {
                byPercent ? completed : completed + min(total - completed, max(0, size - archiveAtLastFile))
            }
            progress.setCompleted(value)
        }

        private var archiveSize: Int64 {
            Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: Process

    /// Runs a tool and waits. With a `meter`, `handleLine` sees each output line (split at "\n", "\r" and
    /// backspaces) and returns true for progress lines, which stay out of error messages; cancelling stops the tool.
    private static func run(_ tool: URL, _ arguments: [String], in directory: URL? = nil, input: String? = nil,
                            meter: CompressionMeter? = nil, handleLine: (String) -> Bool = { _ in false }) throws {
        if meter?.isCancelled == true { throw CopyEngine.Cancelled() }
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
        if let meter {
            // Output can pause for a long time on a large file, so cancelling and the growth estimate run on their own.
            nonisolated(unsafe) let running = process
            Thread.detachNewThread {
                while running.isRunning {
                    if meter.isCancelled { running.terminate() }
                    meter.update()
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }
        var kept = Data(), pending = Data()
        let separators: Set<UInt8> = [0x0A, 0x0D, 0x08]
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            guard meter != nil else { kept.append(chunk); continue }
            pending.append(chunk)
            while let index = pending.firstIndex(where: separators.contains) {
                let line = pending[pending.startIndex..<index]
                pending = Data(pending[(index + 1)...])
                let text = String(decoding: line, as: UTF8.self)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty, !handleLine(text) { kept.append(line + [0x0A]) }
            }
        }
        kept.append(pending)
        process.waitUntilExit()
        if meter?.isCancelled == true { throw CopyEngine.Cancelled() }
        guard process.terminationStatus == 0 else {
            let message = String(data: kept, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "tar: ", with: "")
            throw Failure(message: message?.isEmpty == false ? message! : "\(tool.lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }
}
