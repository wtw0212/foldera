import AppKit
import UniformTypeIdentifiers

/// Icon lookup with caching. Plain folders get a Windows 11 style yellow folder; everything else uses the system icon.
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static let folder: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            let s = rect.width / 16
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            Theme.folderBack.setFill()
            NSBezierPath(roundedRect: r(1, 2.5, 6.2, 3.5), xRadius: 1.2 * s, yRadius: 1.2 * s).fill()
            NSBezierPath(roundedRect: r(1, 3.6, 14, 9.9), xRadius: 1.3 * s, yRadius: 1.3 * s).fill()
            Theme.folderFront.setFill()
            NSBezierPath(roundedRect: r(1, 5.4, 14, 8.1), xRadius: 1.3 * s, yRadius: 1.3 * s).fill()
            return true
        }
        return image
    }()

    static func icon(for item: FileItem) -> NSImage {
        if item.isDirectory && !item.isPackage && !item.isVolume {
            return folder
        }
        if item.isPackage || item.isVolume || item.contentType?.conforms(to: .application) == true {
            return cached(key: "file:" + item.url.path) { NSWorkspace.shared.icon(forFile: item.url.path) }
        }
        let type = item.contentType ?? .data
        return cached(key: "type:" + type.identifier) { NSWorkspace.shared.icon(for: type) }
    }

    static func icon(forPath url: URL) -> NSImage {
        cached(key: "file:" + url.path) { NSWorkspace.shared.icon(forFile: url.path) }
    }

    private static func cached(key: String, make: () -> NSImage) -> NSImage {
        if let image = cache.object(forKey: key as NSString) { return image }
        let image = make()
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
