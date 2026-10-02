import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Icon lookup with caching. Folders and files get Windows 11 style icons; apps, packages and drives keep their own.
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
        // Everything else gets a Windows-style icon for its kind (photo, video, zip…).
        return FileKind.of(item.url, type: item.contentType).icon
    }

    static func icon(forPath url: URL) -> NSImage {
        if url == BrowserTab.thisMacURL { return NSImage(named: NSImage.computerName) ?? folder }
        return cached(key: "file:" + url.path) { NSWorkspace.shared.icon(forFile: url.path) }
    }

    private static func cached(key: String, make: () -> NSImage) -> NSImage {
        if let image = cache.object(forKey: key as NSString) { return image }
        let image = make()
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// An interface icon: a Fluent UI System Icon from the asset catalog when one exists
/// (e.g. "cut_regular"), otherwise an SF Symbol with that name.
struct AppIcon: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        if NSImage(named: "Fluent/" + name) != nil {
            Image("Fluent/" + name)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
        }
    }
}
