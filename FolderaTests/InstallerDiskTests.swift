import Foundation
import Testing
@testable import Foldera

@MainActor
struct InstallerDiskTests {
    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let message = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "InstallerDiskTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: message, as: UTF8.self)])
        }
    }

    /// Mounts a read-only image laid out like the release DMG: an app with `identifier` and an Applications link.
    private func withInstaller(identifier: String, perform: (URL, URL) async throws -> Void) async throws {
        let fm = FileManager()
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaInstaller-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let contents = root.appendingPathComponent("contents/Foldera.app/Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("contents/Applications").path, withDestinationPath: "/Applications")
        let image = root.appendingPathComponent("installer.dmg"), mount = root.appendingPathComponent("mounted")
        try hdiutil(["create", "-volname", "FOLDERAINSTALLER", "-srcfolder", root.appendingPathComponent("contents").path, "-format", "UDZO", image.path])
        try hdiutil(["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { if fm.fileExists(atPath: mount.appendingPathComponent("Foldera.app").path) { try? hdiutil(["detach", mount.path, "-force"]) } }
        try await perform(root, mount)
    }

    @Test func findsAndEjectsOnlyTheInstallerOfThisApp() async throws {
        let identifier = "com.wtw0212.foldera.installer-test-\(UUID())"
        try await withInstaller(identifier: identifier) { root, mount in
            let installed = root.appendingPathComponent("Applications/Foldera.app")
            let mounted = [URL(fileURLWithPath: "/"), mount]
            let found = InstallerDisk.volumes(app: installed, identifier: identifier, mounted: mounted)
            #expect(found.map(\.standardizedFileURL) == [mount.standardizedFileURL])

            // Another app's image, the copy running from the image itself, and a translocated copy are left mounted.
            #expect(InstallerDisk.volumes(app: installed, identifier: "com.example.other", mounted: mounted).isEmpty)
            #expect(InstallerDisk.volumes(app: installed, identifier: nil, mounted: mounted).isEmpty)
            #expect(InstallerDisk.volumes(app: mount.appendingPathComponent("Foldera.app"), identifier: identifier, mounted: mounted).isEmpty)
            let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Foldera.app")
            #expect(InstallerDisk.volumes(app: translocated, identifier: identifier, mounted: mounted).isEmpty)

            // A failed eject is ignored; a real one unmounts the image.
            await InstallerDisk.ejectAfterInstall(find: { found }, eject: { _ in throw CocoaError(.fileWriteNoPermission) })
            #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("Foldera.app").path))
            await InstallerDisk.ejectAfterInstall(find: { found })
            #expect(!FileManager.default.fileExists(atPath: mount.appendingPathComponent("Foldera.app").path))
        }
    }

    @Test func writableVolumesAreNotInstallers() throws {
        #expect(InstallerDisk.volumes(app: URL(fileURLWithPath: "/Applications/Foldera.app"), identifier: "com.wtw0212.foldera",
                                      mounted: [FileManager.default.temporaryDirectory]).isEmpty)
        #expect(InstallerDisk.volumes(app: URL(fileURLWithPath: "/Applications/Foldera.app"), identifier: "com.wtw0212.foldera", mounted: nil).isEmpty)
    }
}
