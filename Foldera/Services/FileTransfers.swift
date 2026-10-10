import AppKit
import Observation

/// One running copy or move, observed by the progress window.
@Observable
final class FileTransfer: Identifiable {
    nonisolated enum Kind: Sendable { case copy, move, compress, extract }

    let id = UUID()
    let kind: Kind
    let itemCount: Int
    let source: URL
    let destination: URL
    private var startedAt = Date()
    var isPreparing = false
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
        if kind == .extract, destination == ArchiveDirectory.temporaryRoot {
            // Taken out to open, copy or preview: the temporary folder means nothing to the user.
            return L10n.format("transfer.extract.open", itemCount, sourceName)
        }
        let key = switch kind {
        case .copy: "transfer.copy"
        case .move: "transfer.move"
        case .compress: "transfer.compress"
        case .extract: "transfer.extract"
        }
        return L10n.format(key, itemCount, sourceName, destinationName)
    }

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }

    var bytesPerSecond: Double {
        guard !isPreparing else { return 0 }
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed > 0.5 ? Double(completedBytes) / elapsed : 0
    }

    var isCancelled: Bool { progress.isCancelled }

    func cancel() { progress.cancel() }

    func startProgress(totalBytes: Int64) {
        self.totalBytes = totalBytes
        startedAt = Date()
        isPreparing = false
    }

    func refresh() {
        completedBytes = progress.completedBytes
        currentName = progress.currentName
    }
}

/// What a transfer changed, so it can be undone.
nonisolated struct TransferResult: Sendable {
    /// New items in the destination (copies, or moved items at their new location).
    var results: [URL] = []
    var created: [URL] = []
    var moved: [(from: URL, to: URL)] = []
    var moveCleanups: [(source: URL, completeCopy: URL)] = []
    /// Items replaced in the destination, now in the Trash.
    var replaced: [(original: URL, trashed: URL)] = []
    /// Sources a move has finished with (server transfers, which record no undo `moved` pairs), so Cut
    /// knows what is gone.
    var completedSources: [URL] = []
    /// Sources with an authoritative committed destination; Cut must not replay them even if their
    /// deletion fails and leaves the source incomplete.
    var consumedCutSources: [URL] = []
    /// Failure/cancellation can coexist with committed items above.
    var error: Error?
}

/// Runs copies and moves with progress and Explorer-style conflict handling.
@Observable
final class FileTransfers {
    static let shared = FileTransfers()

    private(set) var active: [FileTransfer] = []

    private init() {}

    struct PlanItem: Sendable {
        let source: URL
        let destination: URL
        /// Only moves on volumes supporting exclusive rename can avoid copying data.
        let isRename: Bool
        let deleteSourceAfterCopy: Bool
        var replaceExisting = false
    }

    static func planItem(_ kind: FileTransfer.Kind, source: URL, destination: URL, replaceExisting: Bool = false) -> PlanItem {
        let rename = kind == .move && FileOperations.canRename(source, to: destination)
        return PlanItem(source: source, destination: destination, isRename: rename, deleteSourceAfterCopy: kind == .move && !rename, replaceExisting: replaceExisting)
    }

    nonisolated static func totalBytes(_ plan: [PlanItem], progress: TransferProgress? = nil) throws -> Int64 {
        try plan.filter { !$0.isRename }.reduce(0) { try $0 + CopyEngine.size(of: $1.source, progress: progress) }
    }

    /// Copies or moves `sources` into `directory`, returning committed changes alongside any failure.
    func run(_ kind: FileTransfer.Kind, _ sources: [URL], into directory: URL) async -> TransferResult {
        if directory.isRemote || sources.contains(where: \.isRemote) {
            return await RemoteTransfers(transfers: self).run(kind, sources, into: directory)
        }
        let empty = TransferResult()
        let directory = directory.normalizedFileURL
        let sources = sources.map(\.normalizedFileURL)

        if let source = sources.first(where: { FileOperations.contains($0, directory) }) {
            Self.alert(
                L10n.text("The destination folder is a subfolder of the source folder."),
                detail: L10n.format(kind == .copy ? "“%@” can’t be copied into itself." : "“%@” can’t be moved into itself.", source.lastPathComponent)
            )
            return empty
        }

        // Plan: pick destination names and ask about conflicts.
        var plan: [PlanItem] = []
        let conflicts = ConflictResolver(kind: kind, destination: directory)
        for source in sources {
            let sameFolder = source.deletingLastPathComponent().normalizedFileURL == directory
            if sameFolder && kind == .move { continue }
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            var replaceExisting = false
            if sameFolder {
                destination = FileOperations.uniqueURL(named: source.lastPathComponent, in: directory, copySuffix: true)
            } else if FileOperations.exists(destination) {
                switch conflicts.resolve(name: source.lastPathComponent, remaining: sources.count) {
                case .replace: replaceExisting = true
                case .keepBoth: destination = FileOperations.uniqueURL(named: source.lastPathComponent, in: directory)
                case .skip: continue
                case .cancel: return TransferResult(error: CopyEngine.Cancelled())
                }
            }
            plan.append(Self.planItem(kind, source: source, destination: destination, replaceExisting: replaceExisting))
        }
        guard !plan.isEmpty else { return empty }

        let transfer = FileTransfer(kind: kind, itemCount: plan.count, source: sources[0].deletingLastPathComponent(), destination: directory)
        do {
            let result = try await track(transfer, preparing: { [plan] progress in
                try Self.totalBytes(plan, progress: progress)
            }) { [plan] progress in
                Self.execute(plan, progress: progress)
            }
            if let error = result.error, !(error is CopyEngine.Cancelled) { BrowserTab.present(error) }
            return result
        } catch {
            if !(error is CopyEngine.Cancelled) { BrowserTab.present(error) }
            return TransferResult(error: error)
        }
    }

    nonisolated static func execute(_ plan: [PlanItem], progress: TransferProgress, fileManager: FileManager = .default) -> TransferResult {
        var result = TransferResult()
        var base: Int64 = 0
        for item in plan {
            if progress.isCancelled {
                result.error = CopyEngine.Cancelled()
                return result
            }
            progress.setCurrentName(item.source.lastPathComponent)
            var replacement: (original: URL, trashed: URL)?
            var destinationCreated = false
            do {
                if item.replaceExisting {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: item.destination, resultingItemURL: &trashed)
                    if let trashed {
                        let pair = (original: item.destination, trashed: trashed as URL)
                        replacement = pair
                        result.replaced.append(pair)
                    }
                }
                if progress.isCancelled { throw CopyEngine.Cancelled() }
                let size = item.isRename ? 0 : try CopyEngine.size(of: item.source, progress: progress)
                if item.isRename || item.deleteSourceAfterCopy {
                    try FileOperations.moveItem(item.source, to: item.destination, progress: progress, baseBytes: base, allowRename: item.isRename, fileManager: fileManager)
                    result.moved.append((item.source, item.destination))
                    result.results.append(item.destination)
                } else {
                    try CopyEngine.copy(item.source, to: item.destination, progress: progress, baseBytes: base)
                    destinationCreated = true
                    result.created.append(item.destination)
                    result.results.append(item.destination)
                }
                base += size
                progress.setCompleted(base)
            } catch {
                result.error = (error as? FileChange.Failure)?.cause ?? error
                if let failure = error as? FileChange.Failure, case .created(let urls) = failure.remaining {
                    destinationCreated = !urls.isEmpty
                    result.created += urls
                    result.results += urls
                }
                if let failure = error as? FileChange.Failure, case .moveCleanupPending(let source, let completeCopy) = failure.remaining {
                    destinationCreated = true
                    result.moveCleanups.append((source, completeCopy))
                    result.results.append(completeCopy)
                    result.consumedCutSources.append(source)
                }
                if let replacement, !destinationCreated {
                    do {
                        try FileOperations.moveItem(replacement.trashed, to: replacement.original, fileManager: fileManager)
                        result.replaced.removeLast()
                    } catch {
                        if let failure = error as? FileChange.Failure, case .created(let urls) = failure.remaining {
                            result.created += urls
                            result.results += urls
                        }
                        if let failure = error as? FileChange.Failure {
                            result.moveCleanups += failure.remaining.moveCleanups
                            result.results += failure.remaining.moveCleanups.map(\.completeCopy)
                        }
                        result.error = FileChange.Failure(cause: error, remaining: .trashed([replacement]))
                    }
                }
                return result
            }
        }
        return result
    }

    /// Runs `work` off the main actor while the progress window shows `transfer`.
    func track<T: Sendable>(_ transfer: FileTransfer, totalBytes: Int64 = 0, preparing: (@Sendable (TransferProgress) throws -> Int64)? = nil, _ work: @escaping @Sendable (TransferProgress) throws -> T) async throws -> T {
        transfer.isPreparing = preparing != nil
        begin(transfer)
        defer { end(transfer) }
        let ticker = Task {
            while !Task.isCancelled {
                transfer.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { ticker.cancel(); transfer.refresh() }
        let total = if let preparing {
            try await Task.detached(priority: .userInitiated) { [progress = transfer.progress] in try preparing(progress) }.value
        } else { totalBytes }
        if transfer.isCancelled { throw CopyEngine.Cancelled() }
        transfer.startProgress(totalBytes: total)
        let worker = Task.detached(priority: .userInitiated) { [progress = transfer.progress] in try work(progress) }
        return try await worker.value
    }

    /// Shows a transfer in the progress window until `end`.
    func begin(_ transfer: FileTransfer) {
        active.append(transfer)
        TransferWindow.shared.scheduleShow()
    }

    func end(_ transfer: FileTransfer) {
        active.removeAll { $0.id == transfer.id }
        TransferWindow.shared.hideIfIdle()
    }

    static func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Asks what to do when an item with the same name already exists, like Explorer's "Replace or Skip Files".
final class ConflictResolver {
    enum Choice { case replace, keepBoth, skip, cancel }

    private let kind: FileTransfer.Kind
    private let destination: URL
    private var remembered: Choice?
    /// Replaced in tests.
    var ask: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    init(kind: FileTransfer.Kind, destination: URL) {
        self.kind = kind
        self.destination = destination
    }

    func resolve(name: String, remaining: Int) -> Choice {
        if let remembered { return remembered }
        let alert = NSAlert()
        alert.messageText = L10n.format("The destination already has an item named “%@”", name)
        alert.informativeText = L10n.format(kind == .copy ? "Copying to %@. " : "Moving to %@. ", BrowserTab.displayName(of: destination))
            + L10n.text(destination.isRemote ? "Replacing permanently deletes the existing item on the server." : "Replacing moves the existing item to the Trash.")
        alert.addButton(withTitle: L10n.text("Replace"))
        alert.addButton(withTitle: L10n.text("Keep Both"))
        alert.addButton(withTitle: L10n.text("Skip"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        if remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L10n.text("Do this for all conflicts")
        }
        let choice: Choice = switch ask(alert) {
        case .alertFirstButtonReturn: .replace
        case .alertSecondButtonReturn: .keepBoth
        case .alertThirdButtonReturn: .skip
        default: .cancel
        }
        if alert.suppressionButton?.state == .on, choice != .cancel { remembered = choice }
        return choice
    }
}
