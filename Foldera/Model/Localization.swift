import Foundation

nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", traditionalChinese = "zh-Hant"

    static let preferenceKey = "appLanguage"
    static var saved: AppLanguage { saved(in: .standard) }

    static func saved(in defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .system: L10n.text("Follow System")
        case .english: "English"
        case .traditionalChinese: "繁體中文"
        }
    }

    static func resolve(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: allCases.filter { $0 != .system }.map(\.rawValue), forPreferences: preferences).first ?? "en"
    }

    var localization: String { self == .system ? Self.resolve(Locale.preferredLanguages) : rawValue }
    var locale: Locale { self == .system ? .current : Locale(identifier: rawValue) }
}

/// Native language resources shared by SwiftUI, AppKit and background file-operation errors.
enum L10n {
    static var locale: Locale { AppSettings.shared.language.locale }

    static func text(_ key: String) -> String {
        text(key, language: AppSettings.shared.language)
    }

    nonisolated static func text(_ key: String, language: AppLanguage) -> String {
        let bundle = Bundle.main.path(forResource: language.localization, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? Bundle.main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, language: AppSettings.shared.language, arguments: arguments)
    }

    nonisolated static func format(_ key: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        String(format: text(key, language: language), locale: language.locale, arguments: arguments)
    }
}
