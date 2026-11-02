import XCTest
@testable import EasyFindCore

final class LocalizationTests: XCTestCase {
    func testAutoResolutionFollowsSystemLanguage() {
        XCTAssertEqual(Strings.resolve(.auto, preferredLanguages: ["zh-Hans-CN", "en-US"]).language, .zh)
        XCTAssertEqual(Strings.resolve(.auto, preferredLanguages: ["zh-Hant"]).language, .zh)
        XCTAssertEqual(Strings.resolve(.auto, preferredLanguages: ["en-US"]).language, .en)
        XCTAssertEqual(Strings.resolve(.auto, preferredLanguages: []).language, .en)
    }

    func testForcedLanguagesWinOverSystem() {
        XCTAssertEqual(Strings.resolve(.zh, preferredLanguages: ["en-US"]).language, .zh)
        XCTAssertEqual(Strings.resolve(.en, preferredLanguages: ["zh-Hans"]).language, .en)
    }

    func testRepresentativeStrings() {
        let zh = Strings(language: .zh)
        let en = Strings(language: .en)

        XCTAssertNotEqual(zh.menuOpen, en.menuOpen)
        XCTAssertNotEqual(zh.searchPlaceholder, en.searchPlaceholder)
        XCTAssertNotEqual(zh.automationTitle, en.automationTitle)
        XCTAssertEqual(zh.languageChinese, "中文")
        XCTAssertEqual(en.languageEnglish, "English")
        XCTAssertEqual(zh.visits(1), "1 次")
        XCTAssertEqual(en.visits(1), "1 visit")
        XCTAssertEqual(en.visits(3), "3 visits")
    }

    func testAllSurfacesHaveTextInBothLanguages() {
        for language in [ResolvedLanguage.zh, .en] {
            let strings = Strings(language: language)
            let values = [
                strings.menuOpen, strings.menuAdd, strings.menuSync, strings.menuHotkey,
                strings.menuLanguage, strings.menuDataFolder, strings.menuConfigFile,
                strings.menuReloadConfig, strings.menuFullDiskAccess, strings.menuClearFolders,
                strings.menuQuit, strings.languageAuto, strings.languageChinese,
                strings.languageEnglish, strings.hotkeyCommandG, strings.searchPlaceholder,
                strings.emptyNoData, strings.emptyNoFolders, strings.emptyNoResults,
                strings.appSubtitle, strings.manualSubtitle, strings.addAddressTitle,
                strings.urlLabel, strings.aliasLabel, strings.aliasPlaceholder,
                strings.saveButton, strings.cancelButton, strings.invalidURL,
                strings.clearFoldersTitle, strings.clearFoldersInfo, strings.clearButton,
                strings.fatalTitle, strings.quitButton, strings.automationTitle,
                strings.automationInfo, strings.fdaTitle, strings.fdaInfo,
                strings.openSettingsButton, strings.laterButton
            ]
            XCTAssertFalse(values.contains(where: { $0.isEmpty }))
        }
    }
}