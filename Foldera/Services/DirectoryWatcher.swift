import CoreServices
import Foundation

/// Watches one directory with FSEvents and reports changes to its direct children.
final class DirectoryWatcher {
    private let directory: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory.resolvingSymlinksInPath()
        self.onChange = onChange
        start()
    }

    isolated deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            DirectoryWatcher.callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handle(paths: [String]) {
        let watched = directory.path
        // Ignore activity deeper in the tree; only direct children (or the folder itself) affect the listing.
        let relevant = paths.contains { path in
            let parent = (path as NSString).deletingLastPathComponent
            return parent == watched || path == watched
        }
        if relevant { onChange() }
    }

    private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else { return }
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        // The stream is scheduled on the main queue.
        MainActor.assumeIsolated {
            watcher.handle(paths: paths)
        }
    }
}
