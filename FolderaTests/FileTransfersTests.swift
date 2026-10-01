import Foundation
import Testing
@testable import Foldera

@MainActor
struct FileTransfersTests {
    private let root: URL
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaTransfer-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("dest"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("file.txt"))
    }

    @Test func copyIntoSameFolderMakesNamedCopy() async {
        let result = await FileTransfers.shared.run(.copy, [root.appendingPathComponent("file.txt")], into: root)
        #expect(result.created.map(\.lastPathComponent) == ["file - Copy.txt"])
        #expect(fm.fileExists(atPath: root.appendingPathComponent("file.txt").path))
    }

    @Test func moveRelocatesAndRecordsUndoInfo() async {
        let source = root.appendingPathComponent("file.txt")
        let result = await FileTransfers.shared.run(.move, [source], into: root.appendingPathComponent("dest"))
        #expect(!fm.fileExists(atPath: source.path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("dest/file.txt").path))
        #expect(result.moved.count == 1)
        #expect(result.moved.first?.from == source.normalizedFileURL)
    }

    @Test func moveIntoSameFolderDoesNothing() async {
        let result = await FileTransfers.shared.run(.move, [root.appendingPathComponent("file.txt")], into: root)
        #expect(result.results.isEmpty)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("file.txt").path))
    }
}
