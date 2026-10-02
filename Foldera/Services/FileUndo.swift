import AppKit
import Observation

/// A file system change that can be reverted.
nonisolated enum FileChange: Sendable {
    case created([URL])
    case trashed([(original: URL, trashed: URL)])
    case renamed(from: URL, to: URL)
    case moved([(from: URL, to: URL)])
    /// Several renames applied together (may include swaps).
    case batchRenamed([(from: URL, to: URL)])
    case composite([FileChange])

    /// Exact surviving forward changes, or pending undo steps plus the inverse already performed.
    struct Failure: LocalizedError {
        let cause: Error
        let remaining: FileChange
        var inverse: FileChange = .composite([])
        /// A move copied all data before failing to remove its source.
        var sourceRemovalFailed = false

        var errorDescription: String? { cause.localizedDescription }
        var recoverySuggestion: String? {
            remaining.isEmpty && inverse.isEmpty ? nil : "Some items may have changed. Their remaining changes are available in Undo or Redo."
        }
    }

    init(_ transfer: TransferResult, kind: FileTransfer.Kind) {
        let main: FileChange = kind == .copy ? .created(transfer.created) : .composite([.created(transfer.created), .moved(transfer.moved)])
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

    var createdURLs: [URL] {
        switch self {
        case .created(let urls): urls
        case .composite(let changes): changes.flatMap(\.createdURLs)
        default: []
        }
    }

    var batchRenames: [(from: URL, to: URL)] {
        switch self {
        case .batchRenamed(let pairs): pairs
        case .composite(let changes): changes.flatMap(\.batchRenames)
        default: []
        }
    }
}

/// App-wide undo / redo for file operations, like Explorer's Ctrl+Z / Ctrl+Y.
@Observable
final class FileUndo {
    static let shared = FileUndo()

    private var undoStack: [(change: FileChange, name: String)] = []
    private var redoStack: [(change: FileChange, name: String)] = []

    init() {}

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoTitle: String { undoStack.last.map { "Undo \($0.name)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.name)" } ?? "Redo" }

    func record(_ change: FileChange, name: String) {
        guard !change.isEmpty else { return }
        undoStack.append((change, name))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    @discardableResult
    func undo() -> Error? {
        Self.step(&undoStack, into: &redoStack)
    }

    @discardableResult
    func redo() -> Error? {
        Self.step(&redoStack, into: &undoStack)
    }

    private static func step(_ source: inout [(change: FileChange, name: String)], into destination: inout [(change: FileChange, name: String)]) -> Error? {
        guard let entry = source.popLast() else { return nil }
        do {
            let inverse = try revert(entry.change)
            if !inverse.isEmpty { destination.append((inverse, entry.name)) }
            return nil
        } catch let failure as FileChange.Failure {
            if !failure.remaining.isEmpty { source.append((failure.remaining, entry.name)) }
            if !failure.inverse.isEmpty { destination.append((failure.inverse, entry.name)) }
            return failure
        } catch {
            source.append(entry)
            return error
        }
    }

    /// Performs the inverse of `change` and returns the change that inverse made.
    static func revert(_ change: FileChange) throws -> FileChange {
        let fm = FileManager.default
        switch change {
        case .created(let urls):
            if urls.count > 1 { return try revertSteps(urls.map { .created([$0]) }) }
            var pairs: [(original: URL, trashed: URL)] = []
            for url in urls where FileOperations.exists(url) {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed { pairs.append((url, trashed as URL)) }
            }
            return .trashed(pairs)
        case .trashed(let pairs):
            if pairs.count > 1 { return try revertSteps(pairs.reversed().map { .trashed([$0]) }) }
            var restored: [URL] = []
            for pair in pairs.reversed() {
                do {
                    try FileOperations.moveItem(pair.trashed, to: pair.original)
                } catch let failure as FileChange.Failure {
                    // Remove a surviving copy before retrying the restore; keep the Trash receipt.
                    throw inverseMoveFailure(failure, source: pair.trashed, change: change)
                }
                restored.append(pair.original)
            }
            return .created(restored)
        case .renamed(let from, let to):
            do {
                try FileOperations.moveItem(to, to: from)
            } catch let failure as FileChange.Failure {
                throw inverseMoveFailure(failure, source: to, change: change)
            }
            return .renamed(from: to, to: from)
        case .moved(let pairs):
            if pairs.count > 1 { return try revertSteps(pairs.reversed().map { .moved([$0]) }) }
            var back: [(from: URL, to: URL)] = []
            for pair in pairs.reversed() {
                do {
                    try FileOperations.moveItem(pair.to, to: pair.from)
                } catch let failure as FileChange.Failure {
                    // The source may be partially removed. Keep the complete inverse copy,
                    // and let the next Undo remove what remains at the old location.
                    throw inverseMoveFailure(failure, source: pair.to, change: change)
                }
                back.append((pair.to, pair.from))
            }
            return .moved(back)
        case .batchRenamed(let pairs):
            do {
                return .batchRenamed(try BulkRename.apply(pairs.map { ($0.to, $0.from) }))
            } catch let failure as FileChange.Failure {
                let actual = failure.remaining.batchRenames
                var pending: [(from: URL, to: URL)] = []
                var inverse: [(from: URL, to: URL)] = []
                for pair in pairs {
                    let current = actual.first { $0.from.path == pair.to.path }?.to ?? pair.to
                    if current.path == pair.from.path { inverse.append((pair.to, current)) }
                    else { pending.append((pair.from, current)) }
                }
                let remaining: FileChange = failure.remaining.createdURLs.isEmpty ? .batchRenamed(pending)
                    : .composite([.batchRenamed(pending), .created(failure.remaining.createdURLs)])
                throw FileChange.Failure(cause: failure.cause, remaining: remaining, inverse: .batchRenamed(inverse))
            }
        case .composite(let changes):
            return try revertSteps(Array(changes.reversed()))
        }
    }

    private static func inverseMoveFailure(_ failure: FileChange.Failure, source: URL, change: FileChange) -> FileChange.Failure {
        if failure.sourceRemovalFailed {
            return FileChange.Failure(cause: failure.cause, remaining: .created([source]), inverse: failure.remaining)
        }
        return FileChange.Failure(cause: failure.cause, remaining: .composite([change, failure.remaining]))
    }

    /// Steps are in undo order; pending composite changes must retain the opposite order.
    private static func revertSteps(_ steps: [FileChange]) throws -> FileChange {
        var inverse: [FileChange] = []
        for (index, step) in steps.enumerated() {
            do {
                inverse.append(try revert(step))
            } catch let failure as FileChange.Failure {
                let pending = [failure.remaining] + Array(steps.dropFirst(index + 1))
                throw FileChange.Failure(cause: failure.cause, remaining: .composite(Array(pending.reversed())), inverse: .composite(inverse + [failure.inverse]))
            } catch {
                throw FileChange.Failure(cause: error, remaining: .composite(Array(steps[index...].reversed())), inverse: .composite(inverse))
            }
        }
        return .composite(inverse)
    }
}
