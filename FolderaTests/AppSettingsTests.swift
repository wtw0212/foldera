import AppKit
import Testing
@testable import Foldera

@MainActor
struct AppSettingsTests {
    private let preferences: TestPreferences
    init() throws { preferences = try TestPreferences() }

    @Test func firstLaunchDefaults() {
        let settings = AppSettings(defaults: preferences.defaults)
        #expect(settings.language == .system && settings.theme == .system)
        #expect(!settings.showHiddenFiles && settings.showExtensions)
        #expect(!settings.compactView && settings.showNavigationPane)
        #expect(!settings.returnKeyRenames && settings.sidePane == .none)
        #expect(settings.startLocation == .home && settings.terminalApp == "com.apple.Terminal")
        #expect(settings.rowHeight == 30)
    }

    @Test func preferencesSurviveReinitialization() {
        let settings = AppSettings(defaults: preferences.defaults)
        settings.language = .traditionalChinese
        settings.showHiddenFiles = true
        settings.showExtensions = false
        settings.compactView = true
        settings.showNavigationPane = false
        settings.returnKeyRenames = true
        settings.sidePane = .details
        settings.startLocation = .downloads
        settings.terminalApp = "dev.zed.Terminal"
        let restored = AppSettings(defaults: preferences.defaults)
        #expect(restored.language == .traditionalChinese)
        #expect(restored.showHiddenFiles && !restored.showExtensions)
        #expect(restored.compactView && !restored.showNavigationPane && restored.rowHeight == 22)
        #expect(restored.returnKeyRenames && restored.sidePane == .details)
        #expect(restored.startLocation == .downloads && restored.terminalApp == "dev.zed.Terminal")
    }

    @Test(arguments: ["LIGHT", "Dark", "system", "invalid"])
    func savedThemeIsCaseInsensitive(value: String) {
        preferences.defaults.set(value, forKey: "theme")
        #expect(AppSettings(defaults: preferences.defaults).theme == (AppTheme(rawValue: value.lowercased()) ?? .system))
    }

    @Test func invalidPreferencesAndLegacyPreviewHaveSafeFallbacks() {
        for key in ["appLanguage", "startLocation", "sidePane"] {
            preferences.defaults.set("invalid", forKey: key)
        }
        let settings = AppSettings(defaults: preferences.defaults)
        #expect(settings.language == .system && settings.startLocation == .home && settings.sidePane == .none)
        preferences.defaults.set("preview", forKey: "sidePane")
        #expect(AppSettings(defaults: preferences.defaults).sidePane == .details)
    }

    @Test func paneTogglePersistsAndClosesOnSecondClick() {
        let settings = AppSettings(defaults: preferences.defaults)
        settings.toggle(.details)
        #expect(AppSettings(defaults: preferences.defaults).sidePane == .details)
        settings.toggle(.details)
        #expect(AppSettings(defaults: preferences.defaults).sidePane == .none)
    }

    @Test func themeChangesAppearanceAndPersists() {
        let previous = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previous }
        let settings = AppSettings(defaults: preferences.defaults)
        settings.theme = .dark
        #expect(NSApplication.shared.appearance?.name == .darkAqua)
        #expect(AppSettings(defaults: preferences.defaults).theme == .dark)
        settings.theme = .light
        #expect(NSApplication.shared.appearance?.name == .aqua)
        settings.theme = .system
        #expect(NSApplication.shared.appearance == nil)
    }
}
