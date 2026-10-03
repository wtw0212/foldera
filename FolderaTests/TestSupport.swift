import Foundation
import Testing
@testable import Foldera

/// Each test owns its files; cleanup also runs when an expectation throws.
nonisolated final class TestDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderaTests-\(UUID())").normalizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name).normalizedFileURL }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let target = path(name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func file(_ name: String, contents: String = "payload") throws -> URL {
        let target = path(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target)
        return target
    }
}

@MainActor
final class TestPreferences {
    let name = "FolderaTests.\(UUID())"
    let defaults: UserDefaults

    init() throws { defaults = try #require(UserDefaults(suiteName: name)) }

    deinit { UserDefaults.standard.removePersistentDomain(forName: name) }
}

/// A deadline reports the failed condition instead of silently continuing after a fixed sleep.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition())
}
