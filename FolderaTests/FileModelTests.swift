import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Foldera

struct FileModelTests {
    @Test func normalizationKeepsVirtualURLsAndUnifiesDirectoryURLs() {
        let a = URL(fileURLWithPath: "/tmp/folder/../folder", isDirectory: true)
        #expect(a.normalizedFileURL == URL(fileURLWithPath: "/tmp/folder"))
        #expect(a.normalizedFileURL.normalizedFileURL == a.normalizedFileURL)
        let virtual = URL(string: "foldera:this-mac")!
        #expect(virtual.normalizedFileURL == virtual)
    }

    @Test func metadataSeparatesFoldersPackagesDotfilesAndRegularFiles() throws {
        let directory = try TestDirectory()
        let folder = FileItem(url: try directory.folder("notes.txt"))
        let package = FileItem(url: try directory.folder("Demo.app"))
        let hidden = FileItem(url: try directory.file(".secret"))
        let file = FileItem(url: try directory.file("photo.final.txt", contents: "12345"))
        #expect(folder.isNavigable && folder.size == nil && folder.title(showExtensions: false) == "notes.txt")
        #expect(package.isDirectory && package.isPackage && !package.isNavigable)
        #expect(hidden.isHidden && hidden.title(showExtensions: false) == ".secret")
        #expect(file.size == 5 && file.dateModified != nil && file.dateCreated != nil)
        #expect(file.title(showExtensions: false) == "photo.final" && file.title(showExtensions: true) == "photo.final.txt")
        #expect(file.id == file.url && file.contentType?.conforms(to: .text) == true)
    }

    @Test func missingFileStillHasAUsableNameAndIdentity() throws {
        let directory = try TestDirectory()
        let item = FileItem(url: directory.path("missing.txt"))
        #expect(item.name == "missing.txt")
        #expect(!item.isNavigable && item.size == nil && item.kind == "File")
    }

    @Test func directoryLoadingIncludesHiddenItemsAndReportsMissingFolders() async throws {
        let directory = try TestDirectory()
        let file = try directory.file("visible.txt"), hidden = try directory.file(".hidden")
        #expect(Set(try await DirectoryLoader.load(directory.url).map(\.url)) == [file, hidden])
        await #expect(throws: (any Error).self) { try await DirectoryLoader.load(directory.path("missing")) }
    }

    @Test @MainActor func explicitContentTypesTakePrecedenceAndThumbnailPolicyIsSelective() {
        let url = URL(fileURLWithPath: "/nonexistent/file.unknown")
        #expect(FileKind.of(url, type: .pdf) == .pdf)
        #expect(FileKind.of(url, type: .png) == .image)
        #expect(FileKind.of(url, type: .movie) == .video)
        #expect(FileKind.of(url, type: .audio) == .audio)
        #expect(FileKind.of(url, type: .font) == .font)
        #expect(FileKind.of(url, type: nil) == .generic)
        for name in ["photo.JPG", "video.MP4", "document.PDF"] {
            #expect(Thumbnails.showsPreview(FileItem(url: URL(fileURLWithPath: "/nonexistent/" + name))))
        }
        for name in ["text.txt", "archive.zip", "music.mp3", "code.swift"] {
            #expect(!Thumbnails.showsPreview(FileItem(url: URL(fileURLWithPath: "/nonexistent/" + name))))
        }
    }
}

@MainActor
struct DirectoryLoadingPerformanceTests {
    @Test func typeNamesComeFromContentTypesAndAreShared() {
        #expect(TypeNames.name(of: .png) == UTType.png.localizedDescription)
        #expect(TypeNames.name(of: nil) == "File")
        let first = TypeNames.name(of: .pdf), cached = TypeNames.name(of: .pdf)
        #expect(first == UTType.pdf.localizedDescription && cached == first, "a repeated lookup returns the cached name")
    }

    @Test func largeFoldersLoadInParallelInTheSameOrder() async throws {
        let directory = try TestDirectory()
        for index in 0..<(DirectoryLoader.parallelThreshold + 90) {
            try directory.file("item\(index).\(["txt", "png", "swift"][index % 3])")
        }
        try directory.folder("Folder.app")
        try directory.folder("Plain")
        let urls = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: FileItem.resourceKeys)
        let parallel = DirectoryLoader.items(for: urls)
        #expect(parallel == urls.map(FileItem.init(url:)))
        let loaded = try await DirectoryLoader.load(directory.url)
        #expect(loaded.count == urls.count)
        let png = try #require(loaded.first { $0.name == "item1.png" })
        #expect(png.kind == UTType.png.localizedDescription && png.contentType == .png)
        let app = try #require(loaded.first { $0.name == "Folder.app" })
        #expect(app.isPackage && !app.isNavigable && app.kind != "Folder")
        #expect(try #require(loaded.first { $0.name == "Plain" }).kind == "Folder")
    }

    @Test func thumbnailCacheCostsAreDecodedBytes() {
        let image = NSImage(size: NSSize(width: 100, height: 50))
        #expect(Thumbnails.cost(of: image) == 100 * 50 * 4)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let retina = NSImage(size: NSSize(width: 100, height: 50))
        retina.addRepresentation(bitmap)
        #expect(Thumbnails.cost(of: retina) == 200 * 100 * 4)
        #expect(Thumbnails.memoryLimit == 64 * 1024 * 1024)
    }

    @Test func wideColorThumbnailsAreCachedAtEightBitsPerChannel() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(
            data: nil, width: 6, height: 4, bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        let source = try #require(context.makeImage())
        #expect(source.bitsPerPixel == 64)

        let image = try #require(Thumbnails.compact(source, size: NSSize(width: 3, height: 2)))
        let compact = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(compact.bitsPerPixel == 32 && compact.width == 6 && compact.height == 4)
        #expect(image.size == NSSize(width: 3, height: 2))
        let bytes = compact.bytesPerRow * compact.height
        #expect(Thumbnails.cost(of: image) == bytes)
        // A size that doesn't match the main screen's scale, as for a window on another display.
        #expect(Thumbnails.cost(of: NSImage(cgImage: compact, size: NSSize(width: 6, height: 4))) == bytes)
        // Still the same red: bytes are BGRA in memory.
        let pixel = try #require(CFDataGetBytePtr(compact.dataProvider?.data))
        #expect((pixel[0], pixel[1], pixel[2], pixel[3]) == (0, 0, 255, 255))
    }

    @Test func shownThumbnailsDontShareTheirCGImageWithTheCache() throws {
        let symbol = try #require(NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let cached = try #require(Thumbnails.compact(symbol, size: NSSize(width: 16, height: 16)))
        let shown = Thumbnails.forDisplay(cached)
        let a = try #require(cached.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let b = try #require(shown.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(a !== b && a.width == b.width && a.height == b.height && shown.size == cached.size)
    }
}
