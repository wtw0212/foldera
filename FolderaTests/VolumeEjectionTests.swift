import AppKit
import SwiftUI
import Testing
import ViewInspector
@testable import Foldera

@MainActor
@Suite(.serialized)
struct VolumeEjectionTests {
    private let drive = Location(url: URL(fileURLWithPath: "/Volumes/USB-Test", isDirectory: true), title: "USB-Test", symbol: "hard_drive_filled", tint: .blue)

    private func texts(_ view: VolumeEjectionBar) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func ejectKeepsTheMainActorFreeAndPreventsDuplicateRequests() async throws {
        let gate = EjectGate(), errors = ErrorCollector()
        defer { gate.release.signal() }
        let volumes = VolumeMonitor(observe: false, ejectDevice: gate.eject)
        volumes.eject(drive)
        #expect(volumes.isEjecting(drive))
        #expect(volumes.lastEjectedName == nil)
        #expect(try texts(VolumeEjectionBar(volumes: volumes)).contains(L10n.format("Ejecting %@…", drive.title)))
        volumes.eject(drive)
        try await eventually { gate.calls == 1 }
        #expect(!gate.ranOnMainThread)

        // This continuation runs on the main actor while the eject worker is still waiting.
        #expect(volumes.isEjecting(drive) && gate.calls == 1)
        gate.release.signal()
        try await eventually { !volumes.isEjecting(drive) }
        #expect(volumes.lastEjectedName == drive.title && errors.errors.isEmpty)
        let view = VolumeEjectionBar(volumes: volumes)
        #expect(try texts(view).contains(L10n.format("“%@” has been ejected. You can safely remove the device.", drive.title)))
        try view.inspect().find(ViewType.Button.self).tap()
        #expect(volumes.lastEjectedName == nil)
    }

    @Test func aBusyDeviceNeverShowsASafeRemovalNotice() async throws {
        let errors = ErrorCollector()
        let volumes = VolumeMonitor(observe: false, ejectDevice: { _ in throw POSIXError(.EBUSY) })
        volumes.eject(drive)
        try await eventually { !volumes.isEjecting(drive) }
        #expect(errors.errors.count == 1)
        #expect((errors.errors.first as? POSIXError)?.code == .EBUSY)
        #expect(volumes.lastEjectedName == nil)
        #expect(try texts(VolumeEjectionBar(volumes: volumes)).isEmpty)
    }

    @Test func safeRemovalNoticeUsesTheChosenLanguage() async throws {
        let volumes = VolumeMonitor(observe: false, ejectDevice: { _ in })
        volumes.eject(drive)
        try await eventually { volumes.lastEjectedName != nil }
        let original = AppSettings.shared.language
        defer { AppSettings.shared.language = original }
        for (language, expected) in [(AppLanguage.english, "“USB-Test” has been ejected. You can safely remove the device."),
                                     (.traditionalChinese, "「USB-Test」已退出。你可以安全移除設備。")] {
            AppSettings.shared.language = language
            #expect(try texts(VolumeEjectionBar(volumes: volumes)).contains(expected))
        }
    }

    @Test func mountingADriveClearsThePreviousSafeRemovalNotice() async throws {
        let volumes = VolumeMonitor(ejectDevice: { _ in })
        volumes.eject(drive)
        try await eventually { volumes.lastEjectedName != nil }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        #expect(volumes.lastEjectedName == nil)
    }
}

nonisolated private final class EjectGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var mainThread = false
    var calls: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { mainThread } }

    func eject(_ url: URL) throws {
        lock.withLock { count += 1; mainThread = Thread.isMainThread }
        guard release.wait(timeout: .now() + 10) == .success else { throw POSIXError(.ETIMEDOUT) }
    }
}
