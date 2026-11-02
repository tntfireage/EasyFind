import Foundation

public enum ResolvedLanguage: String, Equatable {
    case zh
    case en
}

/// All user-facing strings in one place. Technical tokens (URLs, paths, bundle IDs,
/// logs) are intentionally not translated.
public struct Strings: Equatable {
    public let language: ResolvedLanguage

    public init(language: ResolvedLanguage) {
        self.language = language
    }

    public static func resolve(
        _ configured: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Strings {
        switch configured {
        case .zh:
            return Strings(language: .zh)
        case .en:
            return Strings(language: .en)
        case .auto:
            let first = preferredLanguages.first?.lowercased() ?? ""
            return Strings(language: first.hasPrefix("zh") ? .zh : .en)
        }
    }

    private func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    // MARK: - Menu

    public var menuOpen: String { t("打开 EasyFind", "Open EasyFind") }
    public var menuAdd: String { t("添加地址…", "Add Address…") }
    public var menuSync: String { t("立即同步", "Sync Now") }
    public var menuHotkey: String { t("快捷键", "Hotkey") }
    public var menuLanguage: String { t("语言", "Language") }
    public var menuDataFolder: String { t("打开数据目录", "Open Data Folder") }
    public var menuConfigFile: String { t("打开配置文件", "Open Config File") }
    public var menuReloadConfig: String { t("重新加载配置", "Reload Configuration") }
    public var menuFullDiskAccess: String { t("完全磁盘访问设置", "Full Disk Access Settings") }
    public var menuClearFolders: String { t("清除目录历史", "Clear Folder History") }
    public var menuClearFiles: String { t("清除文件索引", "Clear File Index") }
    public var menuQuit: String { t("退出", "Quit") }

    public var languageAuto: String { t("自动", "Auto") }
    public var languageChinese: String { "中文" }
    public var languageEnglish: String { "English" }

    public var hotkeyCommandG: String {
        t("⌘G（会覆盖“查找下一个”）", "⌘G (overrides Find Next)")
    }

    // MARK: - Panel

    public var searchPlaceholder: String {
        t("搜索地址、应用、目录或文件（~ 只看目录，@ 只看文件）",
          "Search addresses, apps, folders, or files (~ folders, @ files)")
    }
    public var emptyNoData: String {
        t(
            "还没有数据。等待同步，或从菜单栏选择“添加地址…”",
            "No data yet. Wait for a sync, or choose “Add Address…” from the menu bar."
        )
    }
    public var emptyNoFolders: String { t("还没有目录记录", "No folders yet") }
    public var emptyNoFiles: String { t("还没有文件索引", "No files yet") }
    public var emptyNoResults: String { t("没有匹配结果", "No matches") }
    public var appSubtitle: String { t("应用程序", "Application") }
    public var manualSubtitle: String { t("手动", "Manual") }

    public func visits(_ count: Int) -> String {
        if language == .zh {
            return "\(count) 次"
        }
        return count == 1 ? "1 visit" : "\(count) visits"
    }

    // MARK: - Manual entry window

    public var addAddressTitle: String { t("添加地址", "Add Address") }
    public var urlLabel: String { "URL" }
    public var aliasLabel: String { t("别名", "Alias") }
    public var aliasPlaceholder: String { t("例如：API 文档", "e.g. API docs") }
    public var saveButton: String { t("保存", "Save") }
    public var cancelButton: String { t("取消", "Cancel") }
    public var invalidURL: String {
        t("请输入有效的 http/https 地址", "Enter a valid http/https address")
    }

    // MARK: - Alerts

    public var clearFoldersTitle: String { t("清除目录历史？", "Clear folder history?") }
    public var clearFoldersInfo: String {
        t(
            "只删除 EasyFind 的目录索引，不会修改 shell 历史、编辑器最近列表或 Finder 记录。",
            "Only EasyFind's folder index is removed. Shell history, editor recents, and Finder records are untouched."
        )
    }
    public var clearFilesTitle: String { t("清除文件索引？", "Clear file index?") }
    public var clearFilesInfo: String {
        t(
            "只删除 EasyFind 的文件索引与打开次数，下次同步会重新扫描配置中的目录。不会删除任何文件。",
            "Only EasyFind's file index and open counts are removed. The configured directories are rescanned on the next sync. No files are deleted."
        )
    }
    public var clearButton: String { t("清除", "Clear") }

    public var fatalTitle: String { t("EasyFind 无法启动", "EasyFind could not start") }
    public var quitButton: String { t("退出", "Quit") }

    public var automationTitle: String { t("需要自动化权限", "Automation permission required") }
    public var automationInfo: String {
        t(
            "EasyFind 需要读取 Chrome 标签页来保存书签。请在“系统设置 → 隐私与安全性 → 自动化”中允许 EasyFind 控制 Google Chrome。历史记录同步不受影响。",
            "EasyFind needs to read Chrome tabs to save bookmarks. Allow EasyFind to control Google Chrome in System Settings → Privacy & Security → Automation. History sync is unaffected."
        )
    }

    public var fdaTitle: String { t("Safari 历史需要完全磁盘访问", "Safari history requires Full Disk Access") }
    public var fdaInfo: String {
        t(
            "要在 EasyFind 中搜索 Safari 历史，请在“系统设置 → 隐私与安全性 → 完全磁盘访问”中添加 EasyFind，然后重新启动它。其他浏览器和网页档案不受影响。",
            "To search Safari history in EasyFind, add EasyFind under System Settings → Privacy & Security → Full Disk Access, then restart it. Other browsers and the web archive are unaffected."
        )
    }

    public var openSettingsButton: String { t("打开系统设置", "Open System Settings") }
    public var laterButton: String { t("稍后", "Later") }
}