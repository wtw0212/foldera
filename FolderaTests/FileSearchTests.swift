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
}
