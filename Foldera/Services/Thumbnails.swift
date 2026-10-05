import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for the icon views, cached by file, modification date and size.
final class Thumbnails {
    static let shared = Thumbnails()

    private let cache = NSCache<NSString, NSImage>()
    /// Files Quick Look could not thumbnail; they keep their type icon.
    private var failed = Set<String>()

    /// Decoded thumbnails are bitmaps (an extra-large one is about 1 MB), so the cache is bounded by
    /// memory as well as count.
    static let memoryLimit = 96 * 1024 * 1024

    private init() {
        cache.countLimit = 2_000
        cache.totalCostLimit = Self.memoryLimit
    }

    /// Approximate decoded size in bytes.
    static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(pixels, Int(image.size.width * image.size.height)) * 4
    }

    private func key(_ item: FileItem, _ size: CGFloat) -> String {
        let signature = item.url.archiveLocation.flatMap { try? ArchiveSignature($0.archive) }
        return "\(item.url.isFileURL ? item.url.path : item.url.absoluteString)|\(item.dateModified?.timeIntervalSince1970 ?? 0)|\(Int(size))|\(signature?.cacheKey ?? "")"
    }

    /// Like Explorer, only photos, videos and PDFs show their contents; other files keep their
    /// type icon (a text file's preview is mostly white at icon sizes).
    static func showsPreview(_ item: FileItem) -> Bool {
        // Server files would have to be downloaded first; archive items are taken out unless they're large.
        guard item.url.isFileURL || (item.url.isInArchive && (item.size ?? 0) <= ArchivePreviews.automaticSizeLimit) else { return false }
        return switch FileKind.of(item.url, type: item.contentType) {
        case .image, .video, .pdf: true
        default: false
        }
    }

    func cached(for item: FileItem, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(item, size) as NSString)
    }

    func load(for item: FileItem, size: CGFloat, scale: CGFloat) async -> NSImage? {
        guard !item.isNavigable, !item.isPackage, Self.showsPreview(item) else { return nil }
        let key = key(item, size)
        if let image = cache.object(forKey: key as NSString) { return image }
        guard !failed.contains(key) else { return nil }

        guard let file = item.url.isInArchive ? await ArchivePreviews.shared.file(for: item.url) : item.url else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: file,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        do {
            let image = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            guard key == self.key(item, size) else { return nil }
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            return image
        } catch {
            if failed.count > 10_000 { failed.removeAll() }
            failed.insert(key)
            return nil
        }
    }
}
