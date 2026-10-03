import AppKit
import Testing
@testable import Foldera

@MainActor
struct FileDropTests {
    @Test func rejectsEmptySelfAndDescendantDropsWithAnyModifier() throws {
        let directory = try TestDirectory()
        let source = try directory.folder("source"), child = try directory.folder("source/child")
        for modifiers: NSEvent.ModifierFlags in [[], .option, .command] {
            #expect(FileDrop.operation(for: [], into: directory.url, modifiers: modifiers) == nil)
            #expect(FileDrop.operation(for: [source], into: source, modifiers: modifiers) == nil)
            #expect(FileDrop.operation(for: [source], into: child, modifiers: modifiers) == nil)
        }
    }

    @Test func sameVolumeMovesOptionCopiesAndSameParentMoveDoesNothing() throws {
        let directory = try TestDirectory()
        let source = try directory.file("source.txt"), target = try directory.folder("target")
        #expect(FileDrop.operation(for: [source], into: target, modifiers: []) == .move)
        #expect(FileDrop.operation(for: [source], into: target, modifiers: .option) == .copy)
        #expect(FileDrop.operation(for: [source], into: target, modifiers: .command) == .move)
        #expect(FileDrop.operation(for: [source], into: directory.url, modifiers: []) == nil)
        #expect(FileDrop.operation(for: [source], into: directory.url, modifiers: .option) == .copy)
        #expect(FileDrop.operation(for: [source], into: target, modifiers: [.option, .command]) == .copy)
    }

    @Test func pathPrefixAloneDoesNotMakeAnotherFolderADescendant() throws {
        let directory = try TestDirectory()
        let source = try directory.folder("folder"), sibling = try directory.folder("folder-other")
        #expect(FileDrop.operation(for: [source], into: sibling, modifiers: []) == .move)
    }

    @Test func dragPasteboardReadsOnlyFileURLs() {
        let pasteboard = NSPasteboard(name: .init("FolderaDropTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/file.txt") as NSURL])
        #expect(FileDrop.fileURLs(from: pasteboard) == [URL(fileURLWithPath: "/tmp/file.txt")])
        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        #expect(FileDrop.fileURLs(from: pasteboard).isEmpty)
    }
}
