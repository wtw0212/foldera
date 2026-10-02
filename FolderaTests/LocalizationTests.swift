import Foundation
import Testing
@testable import Foldera

@MainActor
struct LocalizationTests {
    @Test func languageMatchingAndResources() throws {
        #expect(AppLanguage.resolve(["zh-HK", "en"]) == "zh-Hant")
        #expect(AppLanguage.resolve(["zh-TW"]) == "zh-Hant")
        #expect(AppLanguage.resolve(["en-GB"]) == "en")
        #expect(AppLanguage.resolve(["fr-FR"]) == "en")
        var englishKeys: Set<String> = []
        for language in [AppLanguage.english, .traditionalChinese] {
            let path = try #require(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
            for table in ["Localizable.strings", "Localizable.stringsdict", "InfoPlist.strings"] {
                let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(table))
                let entries = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
                let keys = Set(entries.keys.map { table + ":" + $0 })
                if language == .english {
                    englishKeys.formUnion(keys)
                } else {
                    #expect(keys.isSubset(of: englishKeys))
                    #expect(keys.count == englishKeys.filter { $0.hasPrefix(table + ":") }.count)
                }
                if table == "Localizable.strings" {
                    #expect(entries.values.allSatisfy { !($0 as? String ?? "").isEmpty })
                }
            }
        }
        #expect(L10n.text("missing.translation", language: .traditionalChinese) == "missing.translation")
    }

    @Test func pluralsAndArgumentOrder() {
        func format(_ key: String, _ language: AppLanguage, _ args: CVarArg...) -> String {
            L10n.format(key, language: language, arguments: args)
        }
        #expect(format("items.count", .english, 0) == "0 items")
        #expect(format("items.count", .english, 1) == "1 item")
        #expect(format("items.count", .english, 2) == "2 items")
        #expect(format("items.count", .traditionalChinese, 1) == "1 個項目")
        #expect(format("items.selected", .traditionalChinese, 2) == "已選取 2 個項目")
        #expect(format("rename.invalid", .english, 1) == "1 name can’t be used")
        #expect(format("rename.invalid", .english, 2) == "2 names can’t be used")
        #expect(format("%lld%% complete", .traditionalChinese, 25) == "已完成 25%")
        #expect(format("Search %@", .traditionalChinese, "100% 🗂️") == "搜尋 100% 🗂️")
        #expect(format("transfer.copy", .english, 1, "Source", "Target") == "Copying 1 item from Source to Target")
        #expect(format("transfer.move", .traditionalChinese, 2, "來源", "目的地") == "正在從 來源 移動 2 個項目 至 目的地")
    }

    @Test func switchingUpdatesTitlesAndPersistsWithoutChangingIdentity() {
        let settings = AppSettings.shared
        let oldLanguage = settings.language
        let oldPreference = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer {
            settings.language = oldLanguage
            if let oldPreference {
                UserDefaults.standard.set(oldPreference, forKey: AppLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
            }
        }
        settings.language = .traditionalChinese
        #expect(AppLanguage.saved == .traditionalChinese)
        #expect(BrowserTab.displayName(of: BrowserTab.thisMacURL) == "這部 Mac")
        #expect(BrowserTab.pathName(of: BrowserTab.thisMacURL) == "This Mac")
        for (path, name) in [
            ("/Users", "Users"),
            ("/Users/example/Documents", "Documents"),
            ("/Users/example/文件", "文件"),
            ("/Users/example/100% 🗂️", "100% 🗂️")
        ] {
            #expect(BrowserTab.pathName(of: URL(fileURLWithPath: path)) == name)
        }
        #expect(StandardLocations.home.title == "主目錄")
        #expect(StartLocation.downloads.title == "下載項目")
        #expect(ViewMode.details.title == "詳細資料")
        #expect(SortField.name.title == "名稱")
        #expect(SortField.name.rawValue == "name")
        #expect(FileOperations.OperationError.invalidName("bad/name").errorDescription == "「bad/name」不是有效的檔案名稱。")
        settings.language = .english
        #expect(BrowserTab.displayName(of: BrowserTab.thisMacURL) == "This Mac")
        #expect(ViewMode.details.title == "Details")
        #expect(L10n.format("items.count", 1) == "1 item")
    }
}
