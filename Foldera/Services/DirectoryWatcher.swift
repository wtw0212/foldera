import CoreServices
import Foundation

/// Watches direct children, or the whole tree while recursive search is active.
final class DirectoryWatcher {
    var includesDescendants = false
    private let directory: URL
    /// Called with `true` when the folder itself changed, `false` when only something deeper did.
    private let onChange: (_ direct: Bool) -> Void
    private var stream: FSEventStreamRef?

    init(directory: URL, onChange: @escaping (_ direct: Bool) -> Void) {
        self.directory = Self.realPath(directory)
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

    /// FSEvents reports real paths (e.g. /private/tmp); `resolvingSymlinksInPath` would strip /private.
    private static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func handle(paths: [String]) {
        let watched = directory.path
        let direct = paths.contains { path in
            (path as NSString).deletingLastPathComponent == watched || path == watched
        }
        if direct { return onChange(true) }
        let prefix = watched == "/" ? "/" : watched + "/"
        if includesDescendants, paths.contains(where: { $0.hasPrefix(prefix) }) { onChange(false) }
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
