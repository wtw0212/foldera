import Foundation

/// Finder-style "Rename N Items" rules: Replace Text, Add Text and Format.
nonisolated struct BulkRenameRule: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case replace = "Replace Text"
        case add = "Add Text"
        case format = "Format"
        var id: String { rawValue }
    }

    enum Position: String, CaseIterable, Identifiable {
        case after = "after name"
        case before = "before name"
        var id: String { rawValue }
    }

    enum FormatStyle: String, CaseIterable, Identifiable {
        case index = "Name and Index"
        case counter = "Name and Counter"
        case date = "Name and Date"
        var id: String { rawValue }
    }

    var mode: Mode = .replace
    // Replace Text
    var find = ""
    var replaceWith = ""
    var matchCase = false
    var includeExtension = false
    // Add Text
    var addText = ""
    var addPosition: Position = .after
    // Format
    var formatStyle: FormatStyle = .index
    var formatPosition: Position = .after
    var customFormat = "File"
    var startNumber = 1
}

nonisolated enum BulkRename {
    struct Item: Equatable {
        let url: URL
        /// Used by "Name and Date".
        var date: Date?
    }

    /// Splits "photo.final.jpg" into ("photo.final", "jpg"). Folders and dotfiles keep their whole name.
    static func split(_ name: String, isFolder: Bool = false) -> (stem: String, ext: String) {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard !isFolder, !ext.isEmpty, !stem.isEmpty else { return (name, "") }
        return (stem, ext)
    }

    private static func join(_ stem: String, _ ext: String) -> String {
        ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// New names for `items`, in order.
    static func newNames(for items: [Item], rule: BulkRenameRule, folders: Set<URL> = []) -> [String] {
        items.enumerated().map { index, item in
            let name = item.url.lastPathComponent
            let (stem, ext) = split(name, isFolder: folders.contains(item.url))
            switch rule.mode {
            case .replace:
                guard !rule.find.isEmpty else { return name }
                let options: String.CompareOptions = rule.matchCase ? [] : [.caseInsensitive]
                if rule.includeExtension {
                    return name.replacingOccurrences(of: rule.find, with: rule.replaceWith, options: options)
                }
                return join(stem.replacingOccurrences(of: rule.find, with: rule.replaceWith, options: options), ext)
            case .add:
                let newStem = rule.addPosition == .after ? stem + rule.addText : rule.addText + stem
                return join(newStem, ext)
            case .format:
                let number = rule.startNumber + index
                let token: String = switch rule.formatStyle {
                case .index: String(number)
                case .counter: String(format: "%05d", number)
                case .date: dateFormatter.string(from: item.date ?? Date())
                }
                let separator = rule.formatStyle == .date ? " " : ""
                let newStem = rule.formatPosition == .after
                    ? rule.customFormat + separator + token
                    : token + separator + rule.customFormat
                return join(newStem, ext)
            }
        }
    }

    /// Problems by index: invalid names, duplicates within the batch, and clashes with other items on disk.
    static func problems(for items: [Item], newNames: [String]) -> [Int: String] {
        var problems: [Int: String] = [:]
        let renamedPaths = Set(items.map { $0.url.path.lowercased() })
        var seen: [String: Int] = [:]
        for (index, name) in newNames.enumerated() {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
                problems[index] = "Name can’t be empty"
                continue
            }
            if name.contains("/") || name.contains(":") {
                problems[index] = "Names can’t contain “/” or “:”"
                continue
            }
            if name.contains("\0") {
                problems[index] = "Names can’t contain a null character"
                continue
            }
            let target = items[index].url.deletingLastPathComponent().appendingPathComponent(name)
            let key = target.path.lowercased()
            if let first = seen[key] {
                problems[index] = "Same name as another item"
                problems[first] = problems[first] ?? "Same name as another item"
            } else {
                seen[key] = index
            }
            // An existing item that isn't part of this rename would be overwritten.
            if !renamedPaths.contains(key), FileManager.default.fileExists(atPath: target.path) {
                problems[index] = "An item with this name already exists"
            }
        }
        return problems
    }

    /// Renames in two steps (to temporary names, then to the final names) so swaps like a↔b work.
    /// Returns the (from, to) pairs that changed.
    @discardableResult
    static func apply(_ renames: [(from: URL, to: URL)]) throws -> [(from: URL, to: URL)] {
        let changes = renames.filter { $0.from.path != $0.to.path }
        var staged: [(temp: URL, from: URL, to: URL, current: URL)] = []
        do {
            for change in changes {
                let temp = change.from.deletingLastPathComponent()
                    .appendingPathComponent(".foldera-rename-\(UUID().uuidString)")
                try FileOperations.moveItem(change.from, to: temp)
                staged.append((temp, change.from, change.to, temp))
            }
            for index in staged.indices {
                try FileOperations.moveItem(staged[index].temp, to: staged[index].to)
                staged[index].current = staged[index].to
            }
            return changes
        } catch {
            var created = (error as? FileChange.Failure)?.remaining.createdURLs ?? []
            // Free original names before restoring a batch that may contain cycles.
            for index in staged.indices where staged[index].current == staged[index].to {
                do {
                    try FileOperations.moveItem(staged[index].current, to: staged[index].temp)
                    staged[index].current = staged[index].temp
                } catch {
                    created += (error as? FileChange.Failure)?.remaining.createdURLs ?? []
                }
            }
            for index in staged.indices {
                do {
                    try FileOperations.moveItem(staged[index].current, to: staged[index].from)
                    staged[index].current = staged[index].from
                } catch {
                    created += (error as? FileChange.Failure)?.remaining.createdURLs ?? []
                }
            }
            let remaining = staged.filter { $0.current.path != $0.from.path }.map { (from: $0.from, to: $0.current) }
            if !created.isEmpty {
                throw FileChange.Failure(cause: error, remaining: .composite([.batchRenamed(remaining), .created(Array(Set(created)))]))
            }
            if !remaining.isEmpty { throw FileChange.Failure(cause: error, remaining: .batchRenamed(remaining)) }
            throw error
        }
    }
}
