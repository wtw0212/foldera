import Darwin
import Foundation
import Testing
@testable import Foldera

@MainActor
@Suite(.serialized)
struct InstallerDiskTests {
    /// AppKit must keep processing volume notifications while a disk tool waits for them.
    private func run(_ executable: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "InstallerDiskTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
            }
        }.value
    }

    /// Uses the actual packaging marker writer and a disposable read-only disk image.
    private func withInstaller(kind: String = "valid", perform: (URL, URL, URL) async throws -> Void) async throws {
        let directory = try TestDirectory(), fm = FileManager.default
        let installed = directory.path("Applications/Foldera.app")
        try fm.createDirectory(at: installed.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "com.wtw0212.foldera", "CFBundleExecutable": "Foldera",
            "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42", "FolderaInstallerID": UUID().uuidString]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: installed.appendingPathComponent("Contents/Info.plist"))
        try Data("SIGNED EXECUTABLE".utf8).write(to: installed.appendingPathComponent("Contents/MacOS/Foldera"))
        let contents = try directory.folder("build.noindex/dmg"), packaged = contents.appendingPathComponent("Foldera.app")
        try fm.copyItem(at: installed, to: packaged)
        try fm.createSymbolicLink(atPath: contents.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let marker = contents.appendingPathComponent(".foldera-installer.plist")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/installer-receipt.py")
        let fixtureScript = try directory.folder("scripts").appendingPathComponent("installer-receipt.py")
        try await run("/bin/cp", [script.path, fixtureScript.path])
        try await run("/usr/bin/env", ["python3", fixtureScript.path])
        switch kind {
        case "missingReceipt": try fm.removeItem(at: marker)
        case "wrongApplicationsLink":
            try fm.removeItem(at: contents.appendingPathComponent("Applications"))
            try fm.createSymbolicLink(atPath: contents.appendingPathComponent("Applications").path, withDestinationPath: "/tmp")
        case "extraFiles": try Data("BACKUP DATA".utf8).write(to: contents.appendingPathComponent("backup.txt"))
        case "alteredExecutable": try Data("OTHER EXECUTABLE".utf8).write(to: packaged.appendingPathComponent("Contents/MacOS/Foldera"))
        default: break
        }
        let image = directory.path("installer.dmg"), mount = directory.path("mounted")
        try await run("/usr/bin/hdiutil", ["create", "-volname", "Foldera 1.2.3", "-srcfolder", contents.path, "-format", "UDZO", image.path])
        try await run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        var failure: Error?
        do { try await perform(installed, mount, directory.url) } catch { failure = error }
        if fm.fileExists(atPath: mount.appendingPathComponent("Foldera.app").path) {
            try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        }
        if let failure { throw failure }
    }

    @Test func automaticallyEjectsTheMarkedInstallerOfTheInstalledCopy() async throws {
        try await withInstaller { installed, mount, root in
            let applications = [root.appendingPathComponent("Applications", isDirectory: true)]
            let found = InstallerDisk.volumes(app: installed, applications: applications)
            #expect(found.map(\.path) == [mount.resolvingSymlinksInPath().standardizedFileURL.path])
            #expect(InstallerDisk.volumes(app: installed, applications: []).isEmpty)
            #expect(InstallerDisk.volumes(app: mount.appendingPathComponent("Foldera.app"), applications: applications).isEmpty)
            let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Foldera.app")
            #expect(InstallerDisk.volumes(app: translocated, applications: applications).isEmpty)
            #expect(InstallerDisk.volumes(app: installed, applications: applications, images: [root]).isEmpty)

            let infoURL = installed.appendingPathComponent("Contents/Info.plist"), original = try Data(contentsOf: infoURL)
            let info = try #require(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: String])
            for (key, value) in [("CFBundleIdentifier", "com.example.other"), ("CFBundleVersion", "43"),
                                 ("CFBundleShortVersionString", "1.2.4"), ("FolderaInstallerID", UUID().uuidString)] {
                var changed = info
                changed[key] = value
                try PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0).write(to: infoURL)
                #expect(InstallerDisk.volumes(app: installed, applications: applications).isEmpty)
            }
            try original.write(to: infoURL)

            // Normal eject leaves an image in use mounted, then succeeds once the process releases it.
            let busy = Process()
            busy.executableURL = URL(fileURLWithPath: "/bin/sleep")
            busy.arguments = ["30"]
            busy.currentDirectoryURL = mount
            try busy.run()
            await InstallerDisk.ejectAfterInstall(find: { found })
            #expect(FileOperations.exists(mount.appendingPathComponent("Foldera.app")))
            busy.terminate()
            busy.waitUntilExit()
            await InstallerDisk.ejectAfterInstall(find: { found })
            #expect(!FileOperations.exists(mount.appendingPathComponent("Foldera.app")))
        }
    }

    @Test(arguments: ["missingReceipt", "wrongApplicationsLink", "extraFiles", "alteredExecutable"])
    func unrelatedReadOnlyImagesStayMounted(_ kind: String) async throws {
        try await withInstaller(kind: kind) { installed, mount, root in
            let found = InstallerDisk.volumes(app: installed, applications: [root.appendingPathComponent("Applications", isDirectory: true)])
            #expect(found.isEmpty)
            await InstallerDisk.ejectAfterInstall(find: { found })
            #expect(FileOperations.exists(mount.appendingPathComponent("Foldera.app")))
        }
    }

    @Test func manualEjectConfirmsSafeRemovalOnlyAfterTheImageIsEjected() async throws {
        try await withInstaller { _, mount, _ in
            let volumes = VolumeMonitor(observe: false), errors = ErrorCollector()
            let drive = Location(url: mount, title: "Test USB", symbol: "hard_drive_filled", tint: .blue)
            let busy = Process()
            busy.executableURL = URL(fileURLWithPath: "/bin/sleep")
            busy.arguments = ["30"]
            busy.currentDirectoryURL = mount
            try busy.run()
            defer { if busy.isRunning { busy.terminate() } }
            volumes.eject(drive)
            #expect(volumes.isEjecting(drive) && volumes.lastEjectedName == nil)
            try await eventually(timeout: .seconds(20)) { !volumes.isEjecting(drive) }
            #expect(errors.errors.count == 1 && volumes.lastEjectedName == nil)
            #expect(FileOperations.exists(mount.appendingPathComponent("Foldera.app")))
            busy.terminate()
            busy.waitUntilExit()

            volumes.eject(drive)
            try await eventually(timeout: .seconds(20)) { !volumes.isEjecting(drive) }
            #expect(volumes.lastEjectedName == "Test USB")
            #expect(!FileOperations.exists(mount.appendingPathComponent("Foldera.app")))
        }
    }

    @Test func imageDiscoveryExcludesWritableOrOtherUsersImages() throws {
        let entity = ["mount-point": "/Volumes/Foldera"]
        let eligible: [String: Any] = ["writeable": false, "owner-uid": Int(getuid()), "image-path": "/tmp/Foldera.dmg", "system-entities": [entity]]
        func discover(_ image: [String: Any]) throws -> [URL] {
            InstallerDisk.readOnlyImages(from: try PropertyListSerialization.data(fromPropertyList: ["images": [image]], format: .xml, options: 0))
        }
        #expect(try discover(eligible) == [URL(fileURLWithPath: "/Volumes/Foldera", isDirectory: true)])
        for (key, value) in [("writeable", true as Any), ("owner-uid", Int(getuid()) + 1 as Any),
                             ("image-path", "/tmp/backup.sparsebundle" as Any)] {
            var image = eligible
            image[key] = value
            #expect(try discover(image).isEmpty)
        }
        #expect(InstallerDisk.readOnlyImages(from: Data("invalid plist".utf8)).isEmpty)
    }
}
