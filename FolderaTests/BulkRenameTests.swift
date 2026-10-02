import Foundation
import Testing
@testable import Foldera

struct BulkRenameTests {
    private func items(_ names: [String]) -> [BulkRename.Item] {
        names.map { BulkRename.Item(url: URL(fileURLWithPath: "/nonexistent/\($0)")) }
    }

    @Test func replaceTextKeepsExtensionByDefault() {
        var rule = BulkRenameRule()
        rule.find = "jpg"
        rule.replaceWith = "photo"
        #expect(BulkRename.newNames(for: items(["jpg_1.jpg"]), rule: rule) == ["photo_1.jpg"])
        rule.includeExtension = true
        #expect(BulkRename.newNames(for: items(["jpg_1.jpg"]), rule: rule) == ["photo_1.photo"])
    }

    @Test func replaceIsCaseInsensitiveUnlessAsked() {
        var rule = BulkRenameRule()
        rule.find = "img"
        rule.replaceWith = "Trip"
        #expect(BulkRename.newNames(for: items(["IMG_01.png"]), rule: rule) == ["Trip_01.png"])
        rule.matchCase = true
        #expect(BulkRename.newNames(for: items(["IMG_01.png"]), rule: rule) == ["IMG_01.png"])
    }

    @Test func addTextBeforeAndAfter() {
        var rule = BulkRenameRule()
        rule.mode = .add
        rule.addText = "-final"
        #expect(BulkRename.newNames(for: items(["report.docx"]), rule: rule) == ["report-final.docx"])
        rule.addPosition = .before
        rule.addText = "2026 "
        #expect(BulkRename.newNames(for: items(["report.docx"]), rule: rule) == ["2026 report.docx"])
    }

    @Test func formatIndexAndCounter() {
        var rule = BulkRenameRule()
        rule.mode = .format
        rule.customFormat = "Trip"
        rule.startNumber = 7
        #expect(BulkRename.newNames(for: items(["a.jpg", "b.png"]), rule: rule) == ["Trip7.jpg", "Trip8.png"])
        rule.formatStyle = .counter
        rule.formatPosition = .before
        #expect(BulkRename.newNames(for: items(["a.jpg"]), rule: rule) == ["00007Trip.jpg"])
    }

    @Test func formatDateUsesItemDate() {
        var rule = BulkRenameRule()
        rule.mode = .format
        rule.formatStyle = .date
        rule.customFormat = "Scan"
        var item = items(["x.pdf"])[0]
        item.date = DateComponents(calendar: .current, year: 2026, month: 3, day: 4, hour: 5, minute: 6, second: 7).date
        #expect(BulkRename.newNames(for: [item], rule: rule) == ["Scan 2026-03-04 at 05.06.07.pdf"])
    }

    @Test func flagsDuplicatesAndInvalidNames() {
        let problems = BulkRename.problems(for: items(["a.txt", "b.txt", "c.txt"]), newNames: ["same.txt", "same.txt", "bad/name"])
        #expect(problems.keys.sorted() == [0, 1, 2])
    }

    @Test func swapsNamesSafely() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("FolderaBulk-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        try BulkRename.apply([(a, b), (b, a)])
        #expect(try String(contentsOf: a, encoding: .utf8) == "B")
        #expect(try String(contentsOf: b, encoding: .utf8) == "A")
    }

    @Test func finalFailureRollsBackFinalizedNamesAndDependencies() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaRollback-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), c = root.appendingPathComponent("c")
        let invalid = root.appendingPathComponent(String(repeating: "z", count: 4000))
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        try Data("C".utf8).write(to: c)
        #expect(throws: (any Error).self) { try BulkRename.apply([(a, b), (b, c), (c, invalid)]) }
        #expect(try String(contentsOf: a, encoding: .utf8) == "A")
        #expect(try String(contentsOf: b, encoding: .utf8) == "B")
        #expect(try String(contentsOf: c, encoding: .utf8) == "C")
        #expect(Set(try fm.contentsOfDirectory(atPath: root.path)) == ["a", "b", "c"])
    }

    @Test func stagingFailureRestoresEarlierItems() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaStage-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a")
        try Data("A".utf8).write(to: a)
        #expect(throws: (any Error).self) {
            try BulkRename.apply([(a, root.appendingPathComponent("x")), (root.appendingPathComponent("missing"), root.appendingPathComponent("y"))])
        }
        #expect(try String(contentsOf: a, encoding: .utf8) == "A")
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["a"])
    }
}
