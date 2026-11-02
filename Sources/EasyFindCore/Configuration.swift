import Foundation

public enum AppLanguage: String, Codable, Equatable {
    case auto
    case zh
    case en

    public init(from decoder: Decoder) throws {
        let raw = ((try? decoder.singleValueContainer().decode(String.self)) ?? "zh").lowercased()
        if raw.hasPrefix("zh") {
            self = .zh
        } else if raw.hasPrefix("en") {
            self = .en
        } else if raw == "auto" {
            self = .auto
        } else {
            self = .zh
        }
    }
}

public struct HotkeyConfig: Codable, Equatable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct SyncConfig: Codable, Equatable {
    public var intervalMinutes: Int
    public var chromeHistory: Bool
    public var chromeTabs: Bool
    public var apps: Bool
    public var folders: Bool
    public var files: Bool

    public init(intervalMinutes: Int, chromeHistory: Bool, chromeTabs: Bool, apps: Bool,
                folders: Bool, files: Bool = true) {
        self.intervalMinutes = intervalMinutes
        self.chromeHistory = chromeHistory
        self.chromeTabs = chromeTabs
        self.apps = apps
        self.folders = folders
        self.files = files
    }
}

public struct FileSearchConfig: Codable, Equatable {
    /// Directories walked by the file index. `~` is expanded when scanning.
    public var directories: [String]
    /// Upper bound on indexed files per sync; protects against enormous trees.
    public var maxFiles: Int
    /// Include dotfiles and hidden directories (`.git`, `.build`, and similar
    /// noise directories are still skipped).
    public var includeHidden: Bool

    public static let defaultDirectories = ["~/Desktop", "~/Documents", "~/Downloads"]

    public init(directories: [String] = FileSearchConfig.defaultDirectories,
                maxFiles: Int = 20_000,
                includeHidden: Bool = false) {
        self.directories = directories
        self.maxFiles = maxFiles
        self.includeHidden = includeHidden
    }
}

public struct ActionSet: Codable, Equatable {
    public var enter: String
    public var commandEnter: String
    public var optionEnter: String

    public init(enter: String, commandEnter: String, optionEnter: String) {
        self.enter = enter
        self.commandEnter = commandEnter
        self.optionEnter = optionEnter
    }
}

public struct ActionConfig: Codable, Equatable {
    public var web: ActionSet
    public var app: ActionSet
    public var folder: ActionSet
    public var file: ActionSet

    public init(web: ActionSet, app: ActionSet, folder: ActionSet,
                file: ActionSet = ActionSet(enter: "open", commandEnter: "finder", optionEnter: "copy")) {
        self.web = web
        self.app = app
        self.folder = folder
        self.file = file
    }
}

public struct TerminalConfig: Codable, Equatable {
    /// `auto`, `iterm2`, or `terminal`.
    public var application: String

    public init(application: String) {
        self.application = application
    }
}

public struct Configuration: Codable, Equatable {
    public var language: AppLanguage
    public var hotkey: HotkeyConfig
    public var sync: SyncConfig
    public var files: FileSearchConfig
    public var actions: ActionConfig
    public var terminal: TerminalConfig

    public init(language: AppLanguage = .zh,
                hotkey: HotkeyConfig,
                sync: SyncConfig,
                files: FileSearchConfig = FileSearchConfig(),
                actions: ActionConfig,
                terminal: TerminalConfig) {
        self.language = language
        self.hotkey = hotkey
        self.sync = sync
        self.files = files
        self.actions = actions
        self.terminal = terminal
    }

    public static let `default` = Configuration(
        language: .zh,
        hotkey: HotkeyConfig(key: "g", modifiers: ["command"]),
        sync: SyncConfig(
            intervalMinutes: 10,
            chromeHistory: true,
            chromeTabs: true,
            apps: true,
            folders: true,
            files: true
        ),
        files: FileSearchConfig(),
        actions: ActionConfig(
            web: ActionSet(enter: "open", commandEnter: "copy", optionEnter: "copy"),
            app: ActionSet(enter: "open", commandEnter: "finder", optionEnter: "copy"),
            folder: ActionSet(enter: "open", commandEnter: "terminal", optionEnter: "copy"),
            file: ActionSet(enter: "open", commandEnter: "finder", optionEnter: "copy")
        ),
        terminal: TerminalConfig(application: "auto")
    )
}

public enum OpenAction: String, Equatable {
    case open
    case copy
    case terminal
    case finder

    public static func parse(_ raw: String) -> OpenAction? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "open", "browser", "openbrowser", "launch":
            return .open
        case "copy", "copyurl", "copypath":
            return .copy
        case "terminal", "iterm", "iterm2":
            return .terminal
        case "finder", "reveal":
            return .finder
        default:
            return nil
        }
    }
}

public enum ActionModifier: Equatable {
    case none
    case command
    case option
}

public extension ActionConfig {
    func action(for kind: EntryKind, modifier: ActionModifier) -> OpenAction {
        let set: ActionSet
        switch kind {
        case .history, .bookmark, .manual:
            set = web
        case .app:
            set = app
        case .folder:
            set = folder
        case .file:
            set = file
        }

        let raw: String
        switch modifier {
        case .none:
            raw = set.enter
        case .command:
            raw = set.commandEnter
        case .option:
            raw = set.optionEnter
        }

        let action = OpenAction.parse(raw) ?? .open
        return Self.supported(action, for: kind)
    }

    static func supported(_ action: OpenAction, for kind: EntryKind) -> OpenAction {
        switch kind {
        case .history, .bookmark, .manual:
            return (action == .terminal || action == .finder) ? .open : action
        case .app:
            return action == .terminal ? .open : action
        case .folder:
            return action
        case .file:
            return action
        }
    }
}

public enum ConfigurationLoader {
    public static func load(from url: URL) -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let userObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .default
        }

        guard let defaultData = try? JSONEncoder().encode(Configuration.default),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any] else {
            return .default
        }

        let merged = deepMerge(defaults, userObject)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: mergedData) else {
            return .default
        }
        return sanitize(configuration)
    }

    public static func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let baseDictionary = base[key] as? [String: Any],
               let overrideDictionary = value as? [String: Any] {
                result[key] = deepMerge(baseDictionary, overrideDictionary)
            } else {
                result[key] = value
            }
        }
        return result
    }

    public static func sanitize(_ configuration: Configuration) -> Configuration {
        var result = configuration

        let key = result.hotkey.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        result.hotkey.key = key.isEmpty ? Configuration.default.hotkey.key : key
        var modifiers = result.hotkey.modifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if modifiers.isEmpty {
            modifiers = Configuration.default.hotkey.modifiers
        }
        result.hotkey.modifiers = modifiers

        result.sync.intervalMinutes = min(max(result.sync.intervalMinutes, 1), 1440)

        result.files.maxFiles = min(max(result.files.maxFiles, 100), 200_000)
        var directories: [String] = []
        var seenDirectories = Set<String>()
        for raw in result.files.directories {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { continue }
            let key = (trimmed as NSString).expandingTildeInPath
            if seenDirectories.insert(key).inserted {
                directories.append(trimmed)
            }
        }
        result.files.directories = directories.isEmpty ? FileSearchConfig.defaultDirectories : directories

        let terminal = result.terminal.application.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        result.terminal.application = ["auto", "iterm2", "terminal"].contains(terminal) ? terminal : "auto"

        result.actions = ActionConfig(
            web: normalize(result.actions.web),
            app: normalize(result.actions.app),
            folder: normalize(result.actions.folder),
            file: normalize(result.actions.file)
        )

        return result
    }

    private static func normalize(_ set: ActionSet) -> ActionSet {
        ActionSet(
            enter: normalize(set.enter),
            commandEnter: normalize(set.commandEnter),
            optionEnter: normalize(set.optionEnter)
        )
    }

    private static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let action = OpenAction.parse(trimmed) else { return OpenAction.open.rawValue }
        return action.rawValue
    }
}

public final class ConfigurationStore {
    public let url: URL
    public private(set) var configuration: Configuration
    private var lastModified: Date?

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let existed = FileManager.default.fileExists(atPath: url.path)
        if !existed {
            try Self.write(Configuration.default, to: url)
        }
        configuration = ConfigurationLoader.load(from: url)
        if existed {
            try? Self.addLanguageIfMissing(to: url, language: configuration.language)
        }
        lastModified = Self.modificationDate(url)
    }

    /// Returns the new configuration when the file changed on disk.
    @discardableResult
    public func reloadIfChanged() -> Configuration? {
        let current = Self.modificationDate(url)
        guard current != lastModified else { return nil }
        lastModified = current
        configuration = ConfigurationLoader.load(from: url)
        return configuration
    }

    @discardableResult
    public func reload() -> Configuration {
        configuration = ConfigurationLoader.load(from: url)
        lastModified = Self.modificationDate(url)
        return configuration
    }

    public func save(_ configuration: Configuration) throws {
        try Self.write(configuration, to: url)
        self.configuration = configuration
        lastModified = Self.modificationDate(url)
    }

    /// Adds the `language` key to a valid pre-existing config without touching
    /// any other key (including unknown keys).
    private static func addLanguageIfMissing(to url: URL, language: AppLanguage) throws {
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["language"] == nil else { return }

        object["language"] = language.rawValue
        let normalized = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try normalized.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    public static func write(_ configuration: Configuration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}