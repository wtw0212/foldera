import AppKit

/// Shared drop logic for the file list, navigation pane and address bar.
/// Like Explorer: same drive moves, another drive copies. Mac modifiers override: ⌥ copies, ⌘ moves.
enum FileDrop {
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func operation(for urls: [URL], into directory: URL, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> FileTransfer.Kind? {
        let directory = directory.normalizedFileURL
        guard !urls.isEmpty else { return nil }
        // Can't drop a folder into itself or its own subfolder.
        if urls.contains(where: { directory.path == $0.normalizedFileURL.path || directory.path.hasPrefix($0.normalizedFileURL.path + "/") }) {
            return nil
        }
        let flags = modifiers
        if flags.contains(.option) { return .copy }
        let kind: FileTransfer.Kind = flags.contains(.command) || sameVolume(urls[0], directory) ? .move : .copy
        // Moving items onto the folder they're already in does nothing.
        if kind == .move, urls.allSatisfy({ $0.deletingLastPathComponent().normalizedFileURL == directory }) {
            return nil
        }
        return kind
    }

    static func dragOperation(for urls: [URL], into directory: URL) -> NSDragOperation {
        switch operation(for: urls, into: directory) {
        case .copy: .copy
        case .move: .move
        case nil: []
        }
    }

    @discardableResult
    static func perform(_ urls: [URL], into directory: URL) -> Bool {
        guard let kind = operation(for: urls, into: directory) else { return false }
        Task {
            let result = await FileTransfers.shared.run(kind, urls, into: directory)
            FileUndo.shared.record(FileChange(result, kind: kind), name: kind == .copy ? "Copy" : "Move")
        }
        return true
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }
}
