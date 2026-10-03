import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for the icon views, cached by file, modification date and size.
final class Thumbnails {
    static let shared = Thumbnails()

    private let cache = NSCache<NSString, NSImage>()
    /// Files Quick Look could not thumbnail; they keep their type icon.
    private var failed = Set<String>()

    private init() {
        cache.countLimit = 2_000
    }

    private func key(_ item: FileItem, _ size: CGFloat) -> String {
        "\(item.url.path)|\(item.dateModified?.timeIntervalSince1970 ?? 0)|\(Int(size))"
    }

    /// Like Explorer, only photos, videos and PDFs show their contents; other files keep their
    /// type icon (a text file's preview is mostly white at icon sizes).
    static func showsPreview(_ item: FileItem) -> Bool {
        // Server files would have to be downloaded first.
        guard !item.url.isRemote else { return false }
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

        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        do {
            let image = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            cache.setObject(image, forKey: key as NSString)
            return image
        } catch {
            failed.insert(key)
            return nil
        }
    }
}
