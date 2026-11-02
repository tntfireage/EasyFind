import AppKit
import EasyFindCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store?
    private var index: SearchIndex?
    private var panelController: PanelController?
    private var hotkeyManager: HotkeyManager?
    private var syncCoordinator: SyncCoordinator?
    private var statusItem: NSStatusItem?
    private var manualEntryController: ManualEntryController?
    private var configuration: Configuration = .default
    private var configStore: ConfigurationStore?
    private var strings = Strings(language: .zh)

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try Store(path: Self.databasePath())
            let index = SearchIndex()
            self.store = store
            self.index = index

            let configURL = URL(fileURLWithPath: Self.configurationPath())
            let configStore = try? ConfigurationStore(url: configURL)
            if configStore == nil {
                NSLog("EasyFind: configuration store unavailable; using defaults")
            }
            self.configStore = configStore
            let configuration = configStore?.configuration ?? .default
            self.configuration = configuration
            self.strings = Strings.resolve(configuration.language)
            NSLog("EasyFind: UI language %@", strings.language.rawValue)

            let panel = PanelController(index: index, store: store)
            panel.configuration = configuration
            panel.strings = strings
            panel.onWillShow = { [weak self] in
                self?.reloadConfigurationIfChanged()
            }
            panelController = panel

            let hotkey = HotkeyManager()
            hotkey.onPress = { [weak self] in self?.panelController?.toggle() }
            if let settings = HotkeySettings.from(configuration.hotkey) {
                hotkey.register(settings: settings)
            } else {
                NSLog("EasyFind: unsupported hotkey in configuration; falling back to ⌘G")
                hotkey.register(settings: .fallback)
            }
            hotkeyManager = hotkey

            setupStatusItem()
            reloadIndex()

            let sync = SyncCoordinator(
                store: store,
                index: index,
                configuration: configuration,
                intervalOverride: Self.syncIntervalOverride(),
                strings: strings
            )
            sync.onUpdate = { [weak self] in
                self?.panelController?.reloadKeepingSelection()
            }
            syncCoordinator = sync
            sync.start()

            registerLoginItem()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
        } catch {
            presentFatalError(error)
        }
    }

    @objc private func applicationDidResignActive() {
        panelController?.hide()
    }

    // MARK: - Index

    private func reloadIndex() {
        guard let store, let index else { return }
        guard let snapshot = try? store.snapshot() else { return }
        index.update(
            entries: snapshot.entries,
            deepLinks: snapshot.deepLinks,
            apps: snapshot.apps,
            folders: snapshot.folders
        )
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "EasyFind")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            panelController?.toggle()
        }
    }

    private func showStatusMenu() {
        guard let statusItem else { return }
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: strings.menuOpen, action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let addItem = NSMenuItem(title: strings.menuAdd, action: #selector(showManualEntry), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        let syncItem = NSMenuItem(title: strings.menuSync, action: #selector(syncNow), keyEquivalent: "")
        syncItem.target = self
        menu.addItem(syncItem)

        let hotkeyItem = NSMenuItem(title: strings.menuHotkey, action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        for (index, preset) in HotkeySettings.presets.enumerated() {
            let item = NSMenuItem(title: preset.title(strings), action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = HotkeySettings.matches(preset, config: configuration.hotkey) ? .on : .off
            hotkeyMenu.addItem(item)
        }
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        let languageItem = NSMenuItem(title: strings.menuLanguage, action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let languageChoices: [(AppLanguage, String)] = [
            (.auto, strings.languageAuto),
            (.zh, strings.languageChinese),
            (.en, strings.languageEnglish)
        ]
        for (language, title) in languageChoices {
            let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = configuration.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        let dataItem = NSMenuItem(title: strings.menuDataFolder, action: #selector(openDataDirectory), keyEquivalent: "")
        dataItem.target = self
        menu.addItem(dataItem)

        let openConfigItem = NSMenuItem(title: strings.menuConfigFile, action: #selector(openConfigFile), keyEquivalent: "")
        openConfigItem.target = self
        menu.addItem(openConfigItem)

        let reloadConfigItem = NSMenuItem(title: strings.menuReloadConfig, action: #selector(reloadConfiguration), keyEquivalent: "")
        reloadConfigItem.target = self
        menu.addItem(reloadConfigItem)

        let fullDiskAccessItem = NSMenuItem(title: strings.menuFullDiskAccess, action: #selector(openFullDiskAccessSettings), keyEquivalent: "")
        fullDiskAccessItem.target = self
        menu.addItem(fullDiskAccessItem)

        let clearFoldersItem = NSMenuItem(title: strings.menuClearFolders, action: #selector(clearFolderHistory), keyEquivalent: "")
        clearFoldersItem.target = self
        menu.addItem(clearFoldersItem)

        let quitItem = NSMenuItem(title: strings.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openPanel() {
        panelController?.show()
    }

    @objc private func syncNow() {
        syncCoordinator?.syncNow()
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < HotkeySettings.presets.count else { return }
        let preset = HotkeySettings.presets[sender.tag]
        var new = configuration
        new.hotkey = HotkeyConfig(key: preset.key, modifiers: preset.modifiers)
        try? configStore?.save(new)
        applyConfiguration(new)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        var new = configuration
        new.language = language
        try? configStore?.save(new)
        applyConfiguration(new)
    }

    @objc private func openConfigFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.configurationPath()))
    }

    @objc private func reloadConfiguration() {
        guard let configStore else { return }
        applyConfiguration(configStore.reload())
    }

    private func reloadConfigurationIfChanged() {
        guard let configStore, let new = configStore.reloadIfChanged() else { return }
        applyConfiguration(new)
    }

    private func applyConfiguration(_ new: Configuration) {
        let hotkeyChanged = new.hotkey != configuration.hotkey
        configuration = new
        strings = Strings.resolve(new.language)
        NSLog("EasyFind: UI language %@", strings.language.rawValue)
        panelController?.configuration = new
        panelController?.strings = strings
        syncCoordinator?.strings = strings

        if hotkeyChanged {
            if let settings = HotkeySettings.from(new.hotkey) {
                hotkeyManager?.register(settings: settings)
            } else {
                NSLog("EasyFind: unsupported hotkey in configuration; falling back to ⌘G")
                hotkeyManager?.register(settings: .fallback)
            }
        }

        syncCoordinator?.update(configuration: new)
        NSLog("EasyFind: configuration applied")
    }

    @objc private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDataDirectory() {
        let directory = (Self.databasePath() as NSString).deletingLastPathComponent
        NSWorkspace.shared.open(URL(fileURLWithPath: directory))
    }

    @objc private func clearFolderHistory() {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = strings.clearFoldersTitle
        alert.informativeText = strings.clearFoldersInfo
        alert.addButton(withTitle: strings.clearButton)
        alert.addButton(withTitle: strings.cancelButton)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? store.clearFolders()
        reloadIndex()
        panelController?.reloadKeepingSelection()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Manual entry

    @objc private func showManualEntry() {
        panelController?.hide()
        let controller = ManualEntryController(strings: strings) { [weak self] url, alias in
            guard let self, let store = self.store else { return }
            _ = try? store.addManual(url: url, alias: alias)
            self.reloadIndex()
            self.panelController?.reloadKeepingSelection()
        }
        controller.onClose = { [weak self] in
            self?.manualEntryController = nil
        }
        manualEntryController = controller
        controller.show()
    }

    // MARK: - Login item

    private func registerLoginItem() {
        if ProcessInfo.processInfo.environment["EASYFIND_DISABLE_LOGIN_ITEM"] == "1" { return }
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("EasyFind: not running from an app bundle; skipping login item")
            return
        }
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            guard service.status != .enabled else { return }
            do {
                try service.register()
            } catch {
                NSLog("EasyFind: login item registration failed: \(error)")
            }
        }
    }

    // MARK: - Paths

    static func databasePath() -> String {
        if let override = ProcessInfo.processInfo.environment["EASYFIND_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("easyfind.db").path
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("easyfind/easyfind.db").path
    }

    static func configurationPath() -> String {
        if let override = ProcessInfo.processInfo.environment["EASYFIND_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("config.json").path
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("easyfind/config.json").path
    }

    private static func syncIntervalOverride() -> TimeInterval? {
        ProcessInfo.processInfo.environment["EASYFIND_SYNC_INTERVAL"].flatMap(Double.init)
    }

    private func presentFatalError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = strings.fatalTitle
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: strings.quitButton)
        alert.runModal()
        NSApp.terminate(nil)
    }
}