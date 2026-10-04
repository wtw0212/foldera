import Foundation
import Testing
@testable import Foldera

@MainActor
@Suite(.serialized)
struct FileSafetyTests {
    @Test func textCreationPreservesFilesDirectoriesAndDanglingLinks() throws {
        let directory = try TestDirectory()
        let original = try directory.file("New Text Document.txt", contents: "KEEP")
        let link = directory.path("New Text Document (2).txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.path("missing"))
        let occupied = try directory.folder("New Text Document (3).txt")
        try "KEEP DIRECTORY".write(to: occupied.appendingPathComponent("keep"), atomically: true, encoding: .utf8)
        let created = try FileOperations.newTextDocument(in: directory.url)
        #expect(created.lastPathComponent == "New Text Document (4).txt")
        #expect(try String(contentsOf: original, encoding: .utf8) == "KEEP")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == directory.path("missing").path)
        #expect(try String(contentsOf: occupied.appendingPathComponent("keep"), encoding: .utf8) == "KEEP DIRECTORY")
        #expect((try FileManager.default.attributesOfItem(atPath: created.path))[.posixPermissions] as? Int == 0o600)
    }

    @Test func concurrentTextCreationNeverClaimsTheSameName() async throws {
        let directory = try TestDirectory()
        let original = try directory.file("New Text Document.txt", contents: "KEEP")
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<32 {
                group.addTask { try FileOperations.newTextDocument(in: directory.url) }
            }
            var result: [URL] = []
            for try await url in group { result.append(url) }
            return result
        }
        #expect(Set(urls).count == 32)
        #expect(try String(contentsOf: original, encoding: .utf8) == "KEEP")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).count == 33)
    }

    @Test func symlinkedSelfCopyIsRejectedAtTheMutationBoundary() throws {
        let directory = try TestDirectory()
        let source = try directory.folder("source"), child = try directory.folder("source/subdir")
        let original = try directory.file("source/keep", contents: "KEEP")
        let link = directory.path("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
        let destination = link.appendingPathComponent("source")
        #expect(FileOperations.contains(source, link))
        #expect(RemoteTransfers.contains(source, link))
        #expect(throws: FileOperations.OperationError.invalidDestination(destination.path)) {
            try CopyEngine.copy(source, to: destination, progress: TransferProgress(), baseBytes: 0)
        }
        #expect(throws: FileOperations.OperationError.invalidDestination(destination.path)) {
            try FileOperations.moveItem(source, to: destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "KEEP")
    }

    @Test func unrelatedDirectoriesAreNotContained() throws {
        let directory = try TestDirectory()
        let source = try directory.folder("source"), other = try directory.folder("other")
        #expect(!FileOperations.contains(source, other))
        #expect(!FileOperations.contains(source, URL(fileURLWithPath: "/", isDirectory: true)))
        #expect(FileOperations.contains(directory.url, other))
    }

    @Test(arguments: [FileTransfer.Kind.copy, .move])
    func aSourceSymlinkCanBeTransferredIntoItsTarget(_ kind: FileTransfer.Kind) async throws {
        let directory = try TestDirectory(), fm = FileManager.default
        let target = try directory.folder("real/folder"), child = try directory.folder("real/folder/subdir")
        let original = try directory.file("real/folder/keep", contents: "KEEP")
        let source = directory.path("link"), destination = child.appendingPathComponent("link")
        try fm.createSymbolicLink(at: source, withDestinationURL: target)
        #expect(!FileOperations.contains(source, child))
        #expect(!RemoteTransfers.contains(source, child))

        let result = await FileTransfers.shared.run(kind, [source], into: child)
        #expect(result.error == nil)
        #expect(result.results == [destination])
        #expect((try fm.attributesOfItem(atPath: destination.path))[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try fm.destinationOfSymbolicLink(atPath: destination.path) == target.path)
        #expect(FileOperations.exists(source) == (kind == .copy))
        #expect(try String(contentsOf: original, encoding: .utf8) == "KEEP")
        #expect(try fm.contentsOfDirectory(atPath: child.path) == ["link"])
    }

    @Test(arguments: ["-oProxyCommand=touch marker", "-Fprofile", "-iidentity"])
    func sshDestinationIsNeverConsumedAsAnOption(_ username: String) throws {
        let endpoint = RemoteEndpoint(host: "127.0.0.1", username: username)
        let generated = BrowserTab.sshCommand(for: endpoint, path: "/", site: nil)
        // -G validates/parses the actual generated command without connecting or running ProxyCommand.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "/usr/bin/ssh -G -F none " + generated.dropFirst(4)]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 255)
        #expect(String(decoding: data, as: UTF8.self).contains("remote username contains invalid characters"))
    }
}
