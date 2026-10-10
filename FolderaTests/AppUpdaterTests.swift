import Foundation
import Testing
import ViewInspector
@testable import Foldera

@MainActor
struct AppUpdaterTests {
    @Test func releaseFeedIsSignedAndTestBuildsStayOffline() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["SUFeedURL"] as? String == "https://github.com/wtw0212/foldera/releases/latest/download/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(!AppUpdater.startsAutomatically)
        #expect(!AppUpdater(starting: false).canCheckForUpdates)
    }

    @Test func settingsReachSparkle() throws {
        let defaults = UserDefaults.standard
        let keys = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

        let updater = AppUpdater(starting: false)
        updater.automaticallyChecks = false
        updater.automaticallyInstalls = false
        #expect(defaults.bool(forKey: "SUEnableAutomaticChecks") == false)
        #expect(defaults.bool(forKey: "SUAutomaticallyUpdate") == false)
        #expect(AppUpdater(starting: false).automaticallyChecks == false)
        updater.automaticallyChecks = true
        updater.automaticallyInstalls = true
        let reloaded = AppUpdater(starting: false)
        #expect(reloaded.automaticallyChecks && reloaded.automaticallyInstalls)

        let preferences = try TestPreferences()
        let view = GeneralSettings(settings: AppSettings(defaults: preferences.defaults), updater: updater)
        let toggles = try view.inspect().findAll(ViewType.Toggle.self)
        #expect(toggles.count == 2)
        try toggles[1].tap()
        #expect(!updater.automaticallyInstalls && defaults.bool(forKey: "SUAutomaticallyUpdate") == false)
        try toggles[0].tap()
        #expect(!updater.automaticallyChecks)
        #expect(try view.inspect().find(button: L10n.text("Check Now")).isDisabled())
    }
}
