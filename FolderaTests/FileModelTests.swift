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
        #expect(Thumbnails.memoryLimit == 96 * 1024 * 1024)
    }
}
