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
        #expect(item.name == "missing.txt" && item.displayName == "missing.txt")
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
