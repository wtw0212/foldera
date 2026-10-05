import AppKit
import UniformTypeIdentifiers

/// Windows 11 style file icons: a white page with a colored mark for the kind of file
/// (photo, video, music, zip…), drawn in code so they stay sharp at every size.
enum FileKind: CaseIterable {
    case image, video, audio, archive, pdf, document, spreadsheet, presentation
    case code, script, text, font, diskImage, generic

    private static let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "cab", "lzh", "arj", "zst"]
    private static let documentExtensions: Set<String> = ["doc", "docx", "odt", "pages", "rtf", "rtfd"]
    private static let spreadsheetExtensions: Set<String> = ["xls", "xlsx", "ods", "numbers", "csv", "tsv"]
    private static let presentationExtensions: Set<String> = ["ppt", "pptx", "odp", "key"]
    private static let codeExtensions: Set<String> = [
        "swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "cs", "java", "kt", "go", "rs", "py", "rb", "php", "js", "ts",
        "jsx", "tsx", "vue", "css", "scss", "html", "htm", "xml", "json", "yaml", "yml", "toml", "plist", "sql", "lua", "dart",
    ]
    private static let scriptExtensions: Set<String> = ["sh", "zsh", "bash", "fish", "command", "bat", "cmd", "ps1"]
    private static let diskImageExtensions: Set<String> = ["dmg", "iso", "img", "sparseimage", "sparsebundle"]

    /// Extension lists catch formats whose UTType the system doesn't know (7z, rar, tsx…).
    static func of(_ url: URL, type: UTType?) -> FileKind {
        // An item inside an archive is known by its own name, not the archive's.
        let url = url.archiveLocation.map { $0.isRoot ? $0.archive : URL(fileURLWithPath: "/" + $0.path) } ?? url
        let ext = url.pathExtension.lowercased()
        let type = type ?? UTType(filenameExtension: ext)
        func conforms(_ other: UTType) -> Bool { type?.conforms(to: other) == true }

        if conforms(.pdf) { return .pdf }
        // Disk images and MacBinary files also conform to public.archive, so check them first and
        // only treat real compression formats as zips.
        if diskImageExtensions.contains(ext) || conforms(.diskImage) { return .diskImage }
        if archiveExtensions.contains(ext) || Archives.isArchive(url) || conforms(.zip) || conforms(.gzip) || conforms(.bz2) { return .archive }
        if conforms(.image) { return .image }
        if conforms(.movie) || conforms(.video) { return .video }
        if conforms(.audio) { return .audio }
        if spreadsheetExtensions.contains(ext) || conforms(.spreadsheet) { return .spreadsheet }
        if presentationExtensions.contains(ext) || conforms(.presentation) { return .presentation }
        if documentExtensions.contains(ext) || conforms(.rtf) { return .document }
        if scriptExtensions.contains(ext) || conforms(.shellScript) { return .script }
        if codeExtensions.contains(ext) || conforms(.sourceCode) || conforms(.json) || conforms(.xml) || conforms(.html) { return .code }
        if conforms(.font) { return .font }
        if conforms(.text) { return .text }
        return .generic
    }

    var icon: NSImage { FileTypeIcons.image(for: self) }
}

enum FileTypeIcons {
    private static var images: [FileKind: NSImage] = [:]

    static func image(for kind: FileKind) -> NSImage {
        if let image = images[kind] { return image }
        // Drawn on demand at whatever size it is shown (16 pt in lists, 96+ in large icons).
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            draw(kind, scale: rect.width / 16)
            return true
        }
        images[kind] = image
        return image
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor { NSColor(hex: hex, alpha: alpha) }

    private static func draw(_ kind: FileKind, scale s: CGFloat) {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
        func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: rect, xRadius: radius * s, yRadius: radius * s)
        }

        if kind == .archive {
            drawZipFolder(r: r, rounded: rounded)
            return
        }

        // The page: white with a folded top-right corner and a soft outline.
        let page = NSBezierPath()
        page.move(to: p(3.5, 1.5))
        page.line(to: p(9.5, 1.5))
        page.line(to: p(13, 5))
        page.line(to: p(13, 14))
        page.appendArc(withCenter: p(12, 14), radius: 1 * s, startAngle: 0, endAngle: 90)
        page.line(to: p(3.5, 15))
        page.appendArc(withCenter: p(3.5, 14), radius: 1 * s, startAngle: 90, endAngle: 180)
        page.line(to: p(2.5, 2.5))
        page.appendArc(withCenter: p(3.5, 2.5), radius: 1 * s, startAngle: 180, endAngle: 270)
        page.close()
        color(0xFFFFFF).setFill()
        page.fill()
        color(0x8C8C8C).setStroke()
        page.lineWidth = max(0.6, 0.35 * s)
        page.stroke()
        let fold = NSBezierPath()
        fold.move(to: p(9.5, 1.5))
        fold.line(to: p(9.5, 4))
        fold.appendArc(withCenter: p(10.5, 4), radius: 1 * s, startAngle: 180, endAngle: 90, clockwise: true)
        fold.line(to: p(13, 5))
        color(0xE3E3E3).setFill()
        fold.fill()
        color(0x8C8C8C).setStroke()
        fold.lineWidth = page.lineWidth
        fold.stroke()

        func lines(_ hex: UInt32, rows: [CGFloat], from x: CGFloat = 4.5, width: CGFloat = 7) {
            color(hex).setFill()
            for y in rows { rounded(r(x, y, width, 0.9), 0.45).fill() }
        }
        func label(_ text: String, _ hex: UInt32, size: CGFloat, y: CGFloat) {
            let font = NSFont.systemFont(ofSize: size * s, weight: .heavy)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color(hex)])
            let bounds = string.size()
            string.draw(at: NSPoint(x: (8 * s) - bounds.width / 2 + 0.25 * s, y: y * s - bounds.height / 2))
        }

        switch kind {
        case .image:
            color(0x3A96DD).setFill()
            rounded(r(4, 7, 8, 6.5), 1).fill()
            let hill = NSBezierPath()
            hill.move(to: p(4, 13.5))
            hill.line(to: p(7, 9.8))
            hill.line(to: p(9, 12))
            hill.line(to: p(10.3, 10.8))
            hill.line(to: p(12, 12.6))
            hill.line(to: p(12, 13.5))
            hill.close()
            color(0x1B5E9F).setFill()
            hill.fill()
            color(0xFFD54A).setFill()
            NSBezierPath(ovalIn: r(9.6, 8, 1.6, 1.6)).fill()
        case .video:
            color(0x7B4CC9).setFill()
            rounded(r(4, 7, 8, 6.5), 1).fill()
            let play = NSBezierPath()
            play.move(to: p(7, 8.6))
            play.line(to: p(10, 10.25))
            play.line(to: p(7, 11.9))
            play.close()
            color(0xFFFFFF).setFill()
            play.fill()
        case .audio:
            color(0xE8663C).setFill()
            NSBezierPath(ovalIn: r(5, 11, 2.6, 2.2)).fill()
            NSBezierPath(ovalIn: r(8.6, 10, 2.6, 2.2)).fill()
            NSBezierPath(rect: r(6.7, 7.4, 0.9, 4.8)).fill()
            NSBezierPath(rect: r(10.3, 6.4, 0.9, 4.8)).fill()
            let beam = NSBezierPath()
            beam.move(to: p(6.7, 7.4))
            beam.line(to: p(11.2, 6.4))
            beam.line(to: p(11.2, 7.8))
            beam.line(to: p(6.7, 8.8))
            beam.close()
            beam.fill()
        case .pdf:
            color(0xD93025).setFill()
            rounded(r(3.2, 8.4, 9.6, 4.6), 0.8).fill()
            label("PDF", 0xFFFFFF, size: 3.4, y: 10.7)
        case .document:
            lines(0xC8C8C8, rows: [5.2])
            color(0x2B5CB8).setFill()
            rounded(r(4, 7.4, 8, 6), 1).fill()
            lines(0xFFFFFF, rows: [9, 10.7, 12.4], from: 5.2, width: 5.6)
        case .spreadsheet:
            color(0x1D8E4F).setFill()
            rounded(r(4, 7, 8, 6.5), 1).fill()
            color(0xFFFFFF, 0.9).setFill()
            for x: CGFloat in [6.6, 9.3] { NSBezierPath(rect: r(x, 7, 0.6, 6.5)).fill() }
            for y: CGFloat in [9.1, 11.3] { NSBezierPath(rect: r(4, y, 8, 0.6)).fill() }
        case .presentation:
            color(0xD24726).setFill()
            rounded(r(4, 7, 8, 6.5), 1).fill()
            color(0xFFFFFF).setFill()
            NSBezierPath(ovalIn: r(5.2, 8.4, 3.6, 3.6)).fill()
            NSBezierPath(rect: r(9.4, 8.6, 1.6, 0.8)).fill()
            NSBezierPath(rect: r(9.4, 10.2, 1.6, 0.8)).fill()
            NSBezierPath(rect: r(9.4, 11.8, 1.6, 0.8)).fill()
        case .code:
            color(0x2F7DD1).setStroke()
            let code = NSBezierPath()
            code.lineWidth = 1.1 * s
            code.lineCapStyle = .round
            code.lineJoinStyle = .round
            code.move(to: p(6.4, 8))
            code.line(to: p(4.4, 10.3))
            code.line(to: p(6.4, 12.6))
            code.move(to: p(9.6, 8))
            code.line(to: p(11.6, 10.3))
            code.line(to: p(9.6, 12.6))
            code.move(to: p(8.7, 7.6))
            code.line(to: p(7.3, 13))
            code.stroke()
        case .script:
            color(0x2D2D2D).setFill()
            rounded(r(4, 7, 8, 6.5), 1).fill()
            color(0x6CCB5F).setStroke()
            let prompt = NSBezierPath()
            prompt.lineWidth = 0.9 * s
            prompt.lineCapStyle = .round
            prompt.move(to: p(5.4, 8.6))
            prompt.line(to: p(7, 10.1))
            prompt.line(to: p(5.4, 11.6))
            prompt.move(to: p(8, 12))
            prompt.line(to: p(10.6, 12))
            prompt.stroke()
        case .text:
            lines(0x9E9E9E, rows: [6.2, 8.2, 10.2, 12.2])
        case .font:
            label("Aa", 0x3B3B3B, size: 5.2, y: 10.3)
        case .diskImage:
            color(0x7A8594).setFill()
            NSBezierPath(ovalIn: r(4.6, 7, 6.8, 6.8)).fill()
            color(0xFFFFFF).setFill()
            NSBezierPath(ovalIn: r(7.2, 9.6, 1.6, 1.6)).fill()
        case .generic, .archive:
            break
        }
    }

    /// Explorer shows zip files as a folder with a zipper ("Compressed (zipped) folder").
    private static func drawZipFolder(r: (CGFloat, CGFloat, CGFloat, CGFloat) -> NSRect, rounded: (NSRect, CGFloat) -> NSBezierPath) {
        Theme.folderBack.setFill()
        rounded(r(1, 2.5, 6.2, 3.5), 1.2).fill()
        rounded(r(1, 3.6, 14, 9.9), 1.3).fill()
        Theme.folderFront.setFill()
        rounded(r(1, 5.4, 14, 8.1), 1.3).fill()
        NSColor(hex: 0x5A4632).setFill()
        rounded(r(7.1, 3.6, 1.8, 9.9), 0.3).fill()
        NSColor(hex: 0xF5D78A).setFill()
        for (index, y) in stride(from: CGFloat(4.4), through: 12.2, by: 1.3).enumerated() {
            rounded(r(index.isMultiple(of: 2) ? 7.1 : 8, y, 0.9, 0.6), 0.2).fill()
        }
        NSColor(hex: 0xC9CDD2).setFill()
        rounded(r(6.6, 9.2, 2.8, 2.6), 0.5).fill()
    }
}
