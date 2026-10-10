import Foundation
import Testing
@testable import Foldera

struct FileSearchTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaSearch-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in ["top report.pdf", "a/notes.txt", "a/b/c/deep Report.pdf", "a/.hidden report.pdf"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(path).path, contents: Data())
        }
    }

    private func names(_ query: String, hidden: Bool = false) async -> Set<String> {
        var result: Set<String> = []
        for await batch in FileSearch.run(in: root, query: query, includeHidden: hidden) {
            result.formUnion(batch.map(\.name))
        }
        return result
    }

    @Test func findsMatchesInNestedFolders() async {
        #expect(await names("report") == ["top report.pdf", "deep Report.pdf"])
    }

    @Test func includesHiddenItemsWhenAsked() async {
        #expect(await names("report", hidden: true).contains(".hidden report.pdf"))
    }

    @Test func supportsWildcards() async {
        #expect(await names("*.txt") == ["notes.txt"])
        #expect(await names("?") == ["a", "b", "c"])
    }

    @Test func folderScopeAndCombinedFilters() async throws {
        let directory = try TestDirectory()
        let image = try directory.file("recent.png")
        let old = try directory.file("old.png")
        try directory.file("notes.txt")
        try directory.file("nested/other.png")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: old.path)
        var found: [FileItem] = []
        let filters = FileSearch.Filters(kind: .images, modified: .week, size: .small)
        for await batch in FileSearch.run(in: directory.url, query: "*.png", includeHidden: false, scope: .folder, filters: filters) { found += batch }
        #expect(found.map(\.url) == [image])
        #expect(!filters.matches(FileItem(url: old)))
    }

    @Test func sizeBoundariesAndMissingMetadata() throws {
        let endpoint = try #require(URL(string: "sftp://user@host/")?.remoteEndpoint)
        func item(_ size: Int64?) -> FileItem {
            FileItem(remote: RemoteEntry(path: "/file.txt", isDirectory: false, isSymlink: false, size: size, modified: nil, permissions: nil), endpoint: endpoint)
        }
        #expect(FileSearch.Filters(size: .small).matches(item(999_999)))
        #expect(!FileSearch.Filters(size: .small).matches(item(1_000_000)))
        #expect(FileSearch.Filters(size: .medium).matches(item(1_000_000)))
        #expect(!FileSearch.Filters(size: .medium).matches(item(100_000_000)))
        #expect(FileSearch.Filters(size: .large).matches(item(100_000_000)))
        #expect(!FileSearch.Filters(size: .large).matches(item(nil)))
        #expect(!FileSearch.Filters(modified: .today).matches(item(0)))
    }

    @Test func resultLimitAppliesAfterMetadataFilters() async throws {
        let directory = try TestDirectory()
        for index in 0...FileSearch.maxResults {
            try directory.file("\(index).txt", contents: "")
        }
        try directory.file("only.png")
        var count = 0
        for await batch in FileSearch.run(in: directory.url, query: "", includeHidden: false) { count += batch.count }
        #expect(count == FileSearch.maxResults)
        var filtered: [FileItem] = []
        for await batch in FileSearch.run(in: directory.url, query: "", includeHidden: false, filters: FileSearch.Filters(kind: .images)) { filtered += batch }
        #expect(filtered.map(\.name) == ["only.png"])
    }
}
