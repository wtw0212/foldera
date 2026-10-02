import Darwin
import Foundation

/// Thread-safe progress shared between a worker thread and the UI.
nonisolated final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _completedBytes: Int64 = 0
    private var _currentName = ""
    private var _cancelled = false

    var completedBytes: Int64 { lock.withLock { _completedBytes } }
    var currentName: String { lock.withLock { _currentName } }
    var isCancelled: Bool { lock.withLock { _cancelled } }

    func cancel() { lock.withLock { _cancelled = true } }
    func setCompleted(_ bytes: Int64) { lock.withLock { _completedBytes = bytes } }
    func setCurrentName(_ name: String) { lock.withLock { _currentName = name } }
}

/// Copies files and folders with `copyfile(3)`: clones on APFS when possible, preserves metadata,
/// and reports byte-level progress.
nonisolated enum CopyEngine {
    struct Cancelled: Error {}

    /// Total size of a file or folder tree, in bytes.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true, values.isSymbolicLink != true else { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
        while let child = enumerator?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Copies `source` to `destination` (which must not exist). `baseBytes` is the progress already
    /// completed by earlier items. Only the owned staging directory is cleaned up on failure.
    static func copy(_ source: URL, to destination: URL, progress: TransferProgress, baseBytes: Int64) throws {
        guard source.isFileURL, destination.isFileURL, !source.path.isEmpty, !destination.path.isEmpty,
              !source.path(percentEncoded: false).contains("\0"), !destination.path(percentEncoded: false).contains("\0") else {
            throw FileOperations.OperationError.invalidName(destination.lastPathComponent)
        }
        let fm = FileManager.default
        guard !FileOperations.exists(destination) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        if progress.isCancelled { throw Cancelled() }
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload")
        let context = CallbackContext(progress: progress, baseBytes: baseBytes)
        let state = copyfile_state_alloc()
        guard state != nil else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, source, _, ctx in
            guard let ctx else { return COPYFILE_CONTINUE }
            let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.handle(what: what, stage: stage, state: state, source: source)
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        let result = withExtendedLifetime(context) {
            copyfile(source.path, payload.path, state, flags)
        }
        if result != 0 {
            let code = context.errorCode ?? errno
            if progress.isCancelled { throw Cancelled() }
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: destination.path,
                NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO),
            ])
        }
        if progress.isCancelled { throw Cancelled() }
        try FileOperations.moveItem(payload, to: destination)
    }

    private final class CallbackContext {
        let progress: TransferProgress
        var finishedBytes: Int64
        var errorCode: Int32?

        init(progress: TransferProgress, baseBytes: Int64) {
            self.progress = progress
            self.finishedBytes = baseBytes
        }

        func handle(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?) -> Int32 {
            if stage == COPYFILE_ERR {
                errorCode = errno
                return COPYFILE_QUIT
            }
            if progress.isCancelled { return COPYFILE_QUIT }
            switch (what, stage) {
            case (COPYFILE_RECURSE_FILE, COPYFILE_START):
                if let source { progress.setCurrentName((String(cString: source) as NSString).lastPathComponent) }
            case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
                var info = stat()
                if let source, lstat(source, &info) == 0 { finishedBytes += Int64(info.st_size) }
                progress.setCompleted(finishedBytes)
            case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                progress.setCompleted(finishedBytes + Int64(copied))
            default:
                break
            }
            return COPYFILE_CONTINUE
        }
    }
}
