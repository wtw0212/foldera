import Foundation
import Testing
@testable import Foldera

struct SearchMatcherTests {
    @Test(arguments: [
        (" report ", "Trip REPORT.pdf", true),
        ("cafe", "Café.txt", true),
        ("*.PDF", "report.pdf", true),
        ("*.pdf", "report.pdf.bak", false),
        ("file?.txt", "file1.txt", true),
        ("file?.txt", "file10.txt", false),
        ("[draft]", "report [draft].txt", true),
        ("100%", "100% complete.txt", true),
        ("no-match", "report.pdf", false),
    ])
    func plainTextAndWildcardMatching(query: String, name: String, matches: Bool) {
        #expect(FileSearch.Matcher(query).matches(name) == matches)
    }

    @Test func packageContentsAndHiddenDescendantsAreNotSearched() async throws {
        let directory = try TestDirectory()
        try directory.file("Demo.app/inside-match.txt")
        try directory.file(".hidden/secret-match.txt")
        try directory.file("visible-match.txt")
        var names: Set<String> = []
        for await batch in FileSearch.run(in: directory.url, query: "match", includeHidden: false) {
            names.formUnion(batch.map(\.name))
        }
        #expect(names == ["visible-match.txt"])
        names = []
        for await batch in FileSearch.run(in: directory.url, query: "match", includeHidden: true) {
            names.formUnion(batch.map(\.name))
        }
        #expect(names == ["visible-match.txt", "secret-match.txt"])
    }

    @Test func largeSearchStreamsEveryMatchAndMissingRootFinishes() async throws {
        let directory = try TestDirectory()
        for index in 0..<425 { try directory.file("match\(index).txt", contents: "") }
        var urls = Set<URL>(), batches = 0
        for await batch in FileSearch.run(in: directory.url, query: "match", includeHidden: false) {
            batches += 1
            urls.formUnion(batch.map(\.url))
        }
        #expect(urls.count == 425 && batches >= 3)
        var missingCount = 0
        for await batch in FileSearch.run(in: directory.path("missing"), query: "*", includeHidden: true) {
            missingCount += batch.count
        }
        #expect(missingCount == 0)
    }
}
