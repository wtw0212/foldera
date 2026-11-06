import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for the icon views, cached by file, modification date and size.
final class Thumbnails {
    static let shared = Thumbnails()

    private let cache = NSCache<NSString, NSImage>()
    /// Files Quick Look could not thumbnail; they keep their type icon.
    private var failed = Set<String>()

    /// Decoded thumbnails are bitmaps (an extra-large one is about 0.7 MB), so the cache is bounded by
    /// memory as well as count. Quick Look keeps its own cache on disk, so going past this only costs a short reload.
    static let memoryLimit = 64 * 1024 * 1024

    private init() {
        cache.countLimit = 2_000
        cache.totalCostLimit = Self.memoryLimit
    }

    /// Decoded size in bytes. Not from the image's representations: they report its size times the main screen's scale,
    /// which is wrong for a thumbnail made for a window on another display.
    static func cost(of image: NSImage) -> Int {
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Int(image.size.width * image.size.height) * 4
        }
        return bitmap.bytesPerRow * bitmap.height
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

    /// Thumbnails of wide-color photos come back at 16 bits per channel. At icon sizes 8 are plenty, and that's what `cost` counts.
    static func compact(_ source: CGImage, size: NSSize) -> NSImage? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3), let context = CGContext(
            data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }

    /// The same pixels under a new `CGImage`. Core Animation keeps a copy of each image it shows for as long as that `CGImage`
    /// lives, which would double the whole cache; this way the copy goes when the cell moves on.
    static func forDisplay(_ image: NSImage) -> NSImage {
        guard let copy = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.copy() else { return image }
        return NSImage(cgImage: copy, size: image.size)
    }

    func cached(for item: FileItem, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(item, size) as NSString).map(Self.forDisplay)
    }

    func load(for item: FileItem, size: CGFloat, scale: CGFloat) async -> NSImage? {
        guard !item.isNavigable, !item.isPackage, Self.showsPreview(item) else { return nil }
        let key = key(item, size)
        if let image = cache.object(forKey: key as NSString) { return Self.forDisplay(image) }
        guard !failed.contains(key) else { return nil }

        guard let file = item.url.isInArchive ? await ArchivePreviews.shared.file(for: item.url) : item.url else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: file,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        do {
            let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard key == self.key(item, size) else { return nil }
            let image = Self.compact(thumbnail.cgImage, size: thumbnail.nsImage.size) ?? thumbnail.nsImage
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            return Self.forDisplay(image)
        } catch {
            if failed.count > 10_000 { failed.removeAll() }
            failed.insert(key)
            return nil
        }
    }
}
