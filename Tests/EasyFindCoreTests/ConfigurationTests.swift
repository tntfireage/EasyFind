import XCTest
@testable import EasyFindCore

final class ConfigurationTests: XCTestCase {
    func testDefaultConfiguration() {
        let config = Configuration.default
        XCTAssertEqual(config.language, .zh)
        XCTAssertEqual(config.hotkey, HotkeyConfig(key: "g", modifiers: ["command"]))
        XCTAssertEqual(config.sync.intervalMinutes, 10)
        XCTAssertTrue(config.sync.chromeHistory)
        XCTAssertTrue(config.sync.chromeTabs)
        XCTAssertTrue(config.sync.apps)
        XCTAssertTrue(config.sync.folders)
        XCTAssertEqual(config.terminal.application, "auto")
        XCTAssertEqual(config.actions.folder.commandEnter, "terminal")
        XCTAssertEqual(config.actions.folder.optionEnter, "copy")
        XCTAssertEqual(config.actions.web.commandEnter, "copy")
        XCTAssertEqual(config.actions.app.commandEnter, "finder")
    }

    func testLanguageDecoding() throws {
        XCTAssertEqual(ConfigurationLoader.load(from: try writeJSON(#"{ "language": "en" }"#)).language, .en)
        XCTAssertEqual(ConfigurationLoader.load(from: try writeJSON(#"{ "language": "en-US" }"#)).language, .en)
        XCTAssertEqual(ConfigurationLoader.load(from: try writeJSON(#"{ "language": "zh-Hans" }"#)).language, .zh)
        XCTAssertEqual(ConfigurationLoader.load(from: try writeJSON(#"{ "language": "auto" }"#)).language, .auto)
        XCTAssertEqual(ConfigurationLoader.load(from: try writeJSON(#"{ "language": "fr" }"#)).language, .zh)
        XCTAssertEqual(ConfigurationLoader.load(from: try writeJSON(#"{ "language": 123 }"#)).language, .zh)
    }

    func testPartialOverrideDeepMergesWithDefaults() throws {
        let url = try writeJSON("""
        {
          "hotkey": { "key": "space" },
          "sync": { "intervalMinutes": 30 },
          "actions": { "folder": { "commandEnter": "finder" } },
          "terminal": { "application": "iTerm2" }
        }
        """)

        let config = ConfigurationLoader.load(from: url)
        XCTAssertEqual(config.hotkey.key, "space")
        XCTAssertEqual(config.hotkey.modifiers, ["command"])
        XCTAssertEqual(config.sync.intervalMinutes, 30)
        XCTAssertTrue(config.sync.chromeTabs)
        XCTAssertEqual(config.actions.folder.commandEnter, "finder")
        XCTAssertEqual(config.actions.folder.optionEnter, "copy")
        XCTAssertEqual(config.actions.web.commandEnter, "copy")
        XCTAssertEqual(config.terminal.application, "iterm2")
    }

    func testInvalidJSONFallsBackToDefaults() throws {
        let url = try writeRaw("this is not json")
        XCTAssertEqual(ConfigurationLoader.load(from: url), .default)
    }

    func testInvalidTypeFallsBackToDefaults() throws {
        let url = try writeJSON(#"{ "sync": { "intervalMinutes": "ten" } }"#)
        XCTAssertEqual(ConfigurationLoader.load(from: url), .default)
    }

    func testUnknownKeysAreIgnored() throws {
        let url = try writeJSON(#"{ "unknown": { "nested": true }, "hotkey": { "key": "j" } }"#)
        let config = ConfigurationLoader.load(from: url)
        XCTAssertEqual(config.hotkey.key, "j")
        XCTAssertEqual(config.hotkey.modifiers, ["command"])
    }

    func testIntervalIsClamped() throws {
        XCTAssertEqual(
            ConfigurationLoader.load(from: try writeJSON(#"{ "sync": { "intervalMinutes": 0 } }"#)).sync.intervalMinutes,
            1
        )
        XCTAssertEqual(
            ConfigurationLoader.load(from: try writeJSON(#"{ "sync": { "intervalMinutes": 99999 } }"#)).sync.intervalMinutes,
            1440
        )
    }

    func testTerminalPreferenceIsSanitized() throws {
        XCTAssertEqual(
            ConfigurationLoader.load(from: try writeJSON(#"{ "terminal": { "application": "Terminal" } }"#)).terminal.application,
            "terminal"
        )
        XCTAssertEqual(
            ConfigurationLoader.load(from: try writeJSON(#"{ "terminal": { "application": "wezterm" } }"#)).terminal.application,
            "auto"
        )
    }

    func testActionNamesAreNormalized() throws {
        let url = try writeJSON("""
        { "actions": { "folder": { "enter": "OPEN", "commandEnter": "iterm2", "optionEnter": "CopyPath" } } }
        """)
        let config = ConfigurationLoader.load(from: url)
        XCTAssertEqual(config.actions.folder.enter, "open")
        XCTAssertEqual(config.actions.folder.commandEnter, "terminal")
        XCTAssertEqual(config.actions.folder.optionEnter, "copy")
    }

    func testDefaultActionResolution() {
        let actions = Configuration.default.actions
        XCTAssertEqual(actions.action(for: .folder, modifier: .none), .open)
        XCTAssertEqual(actions.action(for: .folder, modifier: .command), .terminal)
        XCTAssertEqual(actions.action(for: .folder, modifier: .option), .copy)

        XCTAssertEqual(actions.action(for: .app, modifier: .none), .open)
        XCTAssertEqual(actions.action(for: .app, modifier: .command), .finder)
        XCTAssertEqual(actions.action(for: .app, modifier: .option), .copy)

        XCTAssertEqual(actions.action(for: .history, modifier: .none), .open)
        XCTAssertEqual(actions.action(for: .history, modifier: .command), .copy)
        XCTAssertEqual(actions.action(for: .history, modifier: .option), .copy)
    }

    func testUnsupportedAndUnknownActionsFallBackToOpen() throws {
        let unsupported = try writeJSON("""
        { "actions": { "web": { "commandEnter": "terminal" } } }
        """)
        let unsupportedConfig = ConfigurationLoader.load(from: unsupported)
        XCTAssertEqual(unsupportedConfig.actions.action(for: .history, modifier: .command), .open)

        let unknown = try writeJSON("""
        { "actions": { "folder": { "enter": "rm -rf /" } } }
        """)
        let unknownConfig = ConfigurationLoader.load(from: unknown)
        XCTAssertEqual(unknownConfig.actions.folder.enter, "open")
        XCTAssertEqual(unknownConfig.actions.action(for: .folder, modifier: .none), .open)
    }

    func testStoreAddsLanguageToExistingConfig() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"hotkey":{"key":"j"}}"#.utf8).write(to: url)

        let store = try ConfigurationStore(url: url)
        XCTAssertEqual(store.configuration.language, .zh)

        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["language"] as? String, "zh")
        XCTAssertEqual((object["hotkey"] as? [String: Any])?["key"] as? String, "j")
    }

    func testConfigurationStoreCreatesDefaultFileWithPermissions() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")

        let store = try ConfigurationStore(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.configuration, .default)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testConfigurationStoreReloadsChangedFile() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")

        let store = try ConfigurationStore(url: url)
        try Data(#"{ "hotkey": { "key": "j" } }"#.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)],
            ofItemAtPath: url.path
        )

        let reloaded = try XCTUnwrap(store.reloadIfChanged())
        XCTAssertEqual(reloaded.hotkey.key, "j")
        XCTAssertNil(store.reloadIfChanged())
    }

    func testConfigurationStoreSavePersists() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")

        let store = try ConfigurationStore(url: url)
        var config = Configuration.default
        config.terminal.application = "terminal"
        config.sync.intervalMinutes = 42
        try store.save(config)

        XCTAssertEqual(ConfigurationLoader.load(from: url), config)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Helpers

    private func writeJSON(_ string: String) throws -> URL {
        try writeRaw(string)
    }

    private func writeRaw(_ string: String) throws -> URL {
        let directory = try TestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        try Data(string.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }
}