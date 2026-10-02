import AppKit
import Observation

/// One running copy or move, observed by the progress window.
@Observable
final class FileTransfer: Identifiable {
    enum Kind { case copy, move }

    let id = UUID()
    let kind: Kind
    let itemCount: Int
    let source: URL
    let destination: URL
    let startedAt = Date()
    var totalBytes: Int64 = 0
    private(set) var completedBytes: Int64 = 0
    private(set) var currentName = ""
    @ObservationIgnored let progress = TransferProgress()

    init(kind: Kind, itemCount: Int, source: URL, destination: URL) {
        self.kind = kind
        self.itemCount = itemCount
        self.source = source
        self.destination = destination
    }

    var sourceName: String { BrowserTab.displayName(of: source) }
    var destinationName: String { BrowserTab.displayName(of: destination) }

    var title: String {
        L10n.format(kind == .copy ? "transfer.copy" : "transfer.move", itemCount, sourceName, destinationName)
    }

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }

    var bytesPerSecond: Double {
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed > 0.5 ? Double(completedBytes) / elapsed : 0
    }

    var isCancelled: Bool { progress.isCancelled }

    func cancel() { progress.cancel() }

    func refresh() {
        completedBytes = progress.completedBytes
        currentName = progress.currentName
    }
}

/// What a transfer changed, so it can be undone.
struct TransferResult {
    /// New items in the destination (copies, or moved items at their new location).
    var results: [URL] = []
    var created: [URL] = []
    var moved: [(from: URL, to: URL)] = []
    /// Items replaced in the destination, now in the Trash.
    var replaced: [(original: URL, trashed: URL)] = []
}

/// Runs copies and moves with progress and Explorer-style conflict handling.
@Observable
final class FileTransfers {
    static let shared = FileTransfers()

    private(set) var active: [FileTransfer] = []

    private init() {}

    private struct PlanItem: Sendable {
        let source: URL
        let destination: URL
        /// A move on the same volume is an instant rename; everything else copies data.
        let isRename: Bool
        let deleteSourceAfterCopy: Bool
    }

    /// Copies or moves `sources` into `directory`. Returns what changed (empty when cancelled or nothing to do).
    func run(_ kind: FileTransfer.Kind, _ sources: [URL], into directory: URL) async -> TransferResult {
        var result = TransferResult()
        let directory = directory.normalizedFileURL
        let sources = sources.map(\.normalizedFileURL)

        if let source = sources.first(where: { directory.path == $0.path || directory.path.hasPrefix($0.path + "/") }) {
            Self.alert(
                L10n.text("The destination folder is a subfolder of the source folder."),
                detail: L10n.format(kind == .copy ? "“%@” can’t be copied into itself." : "“%@” can’t be moved into itself.", source.lastPathComponent)
            )
            return result
        }

        // Plan: pick destination names and ask about conflicts.
        var plan: [PlanItem] = []
        var toTrash: [URL] = []
        let conflicts = ConflictResolver(kind: kind, destination: directory)
        for source in sources {
            let sameFolder = source.deletingLastPathComponent().normalizedFileURL == directory
            if sameFolder && kind == .move { continue }
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            if sameFolder {
                destination = FileOperations.uniqueURL(named: source.lastPathComponent, in: directory, copySuffix: true)
            } else if FileManager.default.fileExists(atPath: destination.path) {
                switch conflicts.resolve(name: source.lastPathComponent, remaining: sources.count) {
                case .replace: toTrash.append(destination)
                case .keepBoth: destination = FileOperations.uniqueURL(named: source.lastPathComponent, in: directory)
                case .skip: continue
                case .cancel: return result
                }
            }
            let rename = kind == .move && Self.sameVolume(source, directory)
            plan.append(PlanItem(source: source, destination: destination, isRename: rename, deleteSourceAfterCopy: kind == .move && !rename))
        }
        guard !plan.isEmpty else { return result }

        for url in toTrash {
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed { result.replaced.append((url, trashed as URL)) }
            } catch {
                BrowserTab.present(error)
                return result
            }
        }

        let transfer = FileTransfer(kind: kind, itemCount: plan.count, source: sources[0].deletingLastPathComponent(), destination: directory)
        active.append(transfer)
        TransferWindow.shared.scheduleShow()
        defer {
            active.removeAll { $0.id == transfer.id }
            TransferWindow.shared.hideIfIdle()
        }

        let copyPlan = plan.filter { !$0.isRename }
        transfer.totalBytes = await Task.detached { copyPlan.reduce(0) { $0 + CopyEngine.size(of: $1.source) } }.value

        let worker = Task.detached { [plan, progress = transfer.progress] in
            Self.execute(plan, progress: progress)
        }
        let ticker = Task {
            while !Task.isCancelled {
                transfer.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let (done, error) = await worker.value
        ticker.cancel()
        transfer.refresh()

        for item in done {
            result.results.append(item.destination)
            if kind == .copy { result.created.append(item.destination) } else { result.moved.append((item.source, item.destination)) }
        }
        if let error, !(error is CopyEngine.Cancelled) {
            BrowserTab.present(error)
        }
        return result
    }

    private nonisolated static func execute(_ plan: [PlanItem], progress: TransferProgress) -> ([PlanItem], Error?) {
        var done: [PlanItem] = []
        var base: Int64 = 0
        for item in plan {
            if progress.isCancelled { return (done, CopyEngine.Cancelled()) }
            progress.setCurrentName(item.source.lastPathComponent)
            do {
                if item.isRename {
                    try FileManager.default.moveItem(at: item.source, to: item.destination)
                } else {
                    let size = CopyEngine.size(of: item.source)
                    try CopyEngine.copy(item.source, to: item.destination, progress: progress, baseBytes: base)
                    base += size
                    progress.setCompleted(base)
                    if item.deleteSourceAfterCopy {
                        try FileManager.default.removeItem(at: item.source)
                    }
                }
                done.append(item)
            } catch {
                return (done, error)
            }
        }
        return (done, nil)
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    private static func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Asks what to do when an item with the same name already exists, like Explorer's "Replace or Skip Files".
private final class ConflictResolver {
    enum Choice { case replace, keepBoth, skip, cancel }

    private let kind: FileTransfer.Kind
    private let destination: URL
    private var remembered: Choice?

    init(kind: FileTransfer.Kind, destination: URL) {
        self.kind = kind
        self.destination = destination
    }

    func resolve(name: String, remaining: Int) -> Choice {
        if let remembered { return remembered }
        let alert = NSAlert()
        alert.messageText = L10n.format("The destination already has an item named “%@”", name)
        alert.informativeText = L10n.format(kind == .copy ? "Copying to %@. " : "Moving to %@. ", BrowserTab.displayName(of: destination))
            + L10n.text("Replacing moves the existing item to the Trash.")
        alert.addButton(withTitle: L10n.text("Replace"))
        alert.addButton(withTitle: L10n.text("Keep Both"))
        alert.addButton(withTitle: L10n.text("Skip"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        if remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L10n.text("Do this for all conflicts")
        }
        let choice: Choice = switch alert.runModal() {
        case .alertFirstButtonReturn: .replace
        case .alertSecondButtonReturn: .keepBoth
        case .alertThirdButtonReturn: .skip
        default: .cancel
        }
        if alert.suppressionButton?.state == .on, choice != .cancel { remembered = choice }
        return choice
    }
}
