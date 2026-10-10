import AppKit

/// Shared drop logic for the file list, navigation pane and address bar.
/// Like Explorer: same drive moves, another drive copies. Mac modifiers override: ⌥ copies, ⌘ moves.
enum FileDrop {
    /// Local files and SFTP server items being dragged.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        ItemPasteboard.urls(from: pasteboard)
    }

    static func operation(for urls: [URL], into directory: URL, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> FileTransfer.Kind? {
        let directory = directory.normalizedFileURL
        // This Mac, Network and Recent are pages, not folders.
        guard !urls.isEmpty, directory.isFileURL || directory.isRemote else { return nil }
        if urls.contains(where: \.isInArchive) {
            // Items from one archive are extracted into a folder on this Mac: always a copy.
            let archives = Set(urls.compactMap { $0.archiveLocation?.archive })
            return directory.isFileURL && archives.count == 1 && urls.allSatisfy(\.isInArchive) ? .copy : nil
        }
        // Can't drop a folder into itself or its own subfolder.
        if urls.contains(where: { RemoteTransfers.contains($0.normalizedFileURL, directory) }) {
            return nil
        }
        let flags = modifiers
        if flags.contains(.option) { return .copy }
        let kind: FileTransfer.Kind = flags.contains(.command) || sameVolume(urls[0], directory) ? .move : .copy
        // Moving items onto the folder they're already in does nothing.
        if kind == .move, urls.allSatisfy({ RemoteTransfers.parent(of: $0.normalizedFileURL) == directory }) {
            return nil
        }
        return kind
    }

    static func dragOperation(for urls: [URL], into directory: URL) -> NSDragOperation {
        switch operation(for: urls, into: directory) {
        case .copy: .copy
        case .move: .move
        case .compress, .extract, nil: []
        }
    }

    @discardableResult
    static func perform(_ urls: [URL], into directory: URL) -> Bool {
        guard let kind = operation(for: urls, into: directory) else { return false }
        if let archive = urls.first?.archiveLocation?.archive {
            Task {
                do {
                    let created = try await ArchiveExtraction.items(urls.compactMap(\.archiveLocation), from: archive, into: directory) ?? []
                    FileUndo.shared.record(.created(created), name: "Extract")
                } catch {
                    if let partial = error as? FileChange.Failure {
                        FileUndo.shared.record(partial.remaining, name: "Extract")
                    }
                    if !(((error as? FileChange.Failure)?.cause ?? error) is CopyEngine.Cancelled) { BrowserTab.present(error) }
                }
            }
            return true
        }
        Task {
            let result = await FileTransfers.shared.run(kind, urls, into: directory)
            FileUndo.shared.record(FileChange(result, kind: kind), name: kind == .copy ? "Copy" : "Move")
        }
        return true
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        if a.isRemote || b.isRemote { return a.remoteEndpoint != nil && a.remoteEndpoint == b.remoteEndpoint }
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }
}
