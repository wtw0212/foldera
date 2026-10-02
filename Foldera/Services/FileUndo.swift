import AppKit
import Observation

/// A file system change that can be reverted.
enum FileChange {
    case created([URL])
    case trashed([(original: URL, trashed: URL)])
    case renamed(from: URL, to: URL)
    case moved([(from: URL, to: URL)])
    /// Several renames applied together (may include swaps).
    case batchRenamed([(from: URL, to: URL)])
    case composite([FileChange])

    init(_ transfer: TransferResult, kind: FileTransfer.Kind) {
        let main: FileChange = kind == .copy ? .created(transfer.created) : .moved(transfer.moved)
        self = transfer.replaced.isEmpty ? main : .composite([.trashed(transfer.replaced), main])
    }

    var isEmpty: Bool {
        switch self {
        case .created(let urls): urls.isEmpty
        case .trashed(let pairs): pairs.isEmpty
        case .renamed: false
        case .moved(let pairs), .batchRenamed(let pairs): pairs.isEmpty
        case .composite(let changes): changes.allSatisfy(\.isEmpty)
        }
    }
}

/// App-wide undo / redo for file operations, like Explorer's Ctrl+Z / Ctrl+Y.
@Observable
final class FileUndo {
    static let shared = FileUndo()

    private var undoStack: [(change: FileChange, name: String)] = []
    private var redoStack: [(change: FileChange, name: String)] = []

    private init() {}

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoTitle: String { undoStack.last.map { L10n.format("Undo %@", L10n.text($0.name)) } ?? L10n.text("Undo") }
    var redoTitle: String { redoStack.last.map { L10n.format("Redo %@", L10n.text($0.name)) } ?? L10n.text("Redo") }

    func record(_ change: FileChange, name: String) {
        guard !change.isEmpty else { return }
        undoStack.append((change, name))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        do {
            redoStack.append((try Self.revert(entry.change), entry.name))
        } catch {
            BrowserTab.present(error)
        }
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        do {
            undoStack.append((try Self.revert(entry.change), entry.name))
        } catch {
            BrowserTab.present(error)
        }
    }

    /// Performs the inverse of `change` and returns the change that inverse made.
    static func revert(_ change: FileChange) throws -> FileChange {
        let fm = FileManager.default
        switch change {
        case .created(let urls):
            var pairs: [(original: URL, trashed: URL)] = []
            for url in urls where fm.fileExists(atPath: url.path) {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed { pairs.append((url, trashed as URL)) }
            }
            return .trashed(pairs)
        case .trashed(let pairs):
            var restored: [URL] = []
            for pair in pairs.reversed() {
                try fm.moveItem(at: pair.trashed, to: pair.original)
                restored.append(pair.original)
            }
            return .created(restored)
        case .renamed(let from, let to):
            try fm.moveItem(at: to, to: from)
            return .renamed(from: to, to: from)
        case .moved(let pairs):
            var back: [(from: URL, to: URL)] = []
            for pair in pairs.reversed() {
                try fm.moveItem(at: pair.to, to: pair.from)
                back.append((pair.to, pair.from))
            }
            return .moved(back)
        case .batchRenamed(let pairs):
            return .batchRenamed(try BulkRename.apply(pairs.map { ($0.to, $0.from) }))
        case .composite(let changes):
            return .composite(try changes.reversed().map(revert))
        }
    }
}
