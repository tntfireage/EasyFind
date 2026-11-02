import AppKit
import EasyFindCore

final class SyncCoordinator {
    private let store: Store
    private let index: SearchIndex
    private lazy var historyCollector = BrowserHistoryCollector()
    private let tabCollector = ChromeTabCollector()
    private let queue = DispatchQueue(label: "com.easyfind.sync", qos: .utility)
    private var interval: TimeInterval
    private let intervalOverride: TimeInterval?
    private let tabsDisabled: Bool
    private var configuration: Configuration
    var strings: Strings
    private var timer: DispatchSourceTimer?
    private var isSyncing = false

    var onUpdate: (() -> Void)?

    init(store: Store, index: SearchIndex, configuration: Configuration,
         intervalOverride: TimeInterval? = nil, strings: Strings) {
        self.store = store
        self.index = index
        self.configuration = configuration
        self.strings = strings
        self.intervalOverride = intervalOverride
        self.interval = intervalOverride ?? TimeInterval(configuration.sync.intervalMinutes * 60)
        let environment = ProcessInfo.processInfo.environment
        tabsDisabled = environment["EASYFIND_DISABLE_TABS"] == "1"
    }

    /// Applies a reloaded configuration on the sync queue and reschedules the timer.
    func update(configuration newConfiguration: Configuration) {
        queue.async { [weak self] in
            guard let self else { return }
            self.configuration = newConfiguration
            guard self.intervalOverride == nil else { return }
            let newInterval = TimeInterval(newConfiguration.sync.intervalMinutes * 60)
            guard newInterval != self.interval else { return }
            self.interval = newInterval
            self.timer?.schedule(deadline: .now() + newInterval, repeating: newInterval, leeway: .seconds(30))
        }
    }

    func start() {
        syncNow()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.performSync()
        }
        timer.resume()
        self.timer = timer
    }

    func syncNow() {
        queue.async { [weak self] in
            self?.performSync()
        }
    }

    deinit {
        timer?.cancel()
    }

    private func performSync() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            if configuration.sync.chromeHistory {
                let aggregates = historyCollector.collect()
                let upserts = aggregates.map { aggregate in
                    HistoryUpsert(
                        host: aggregate.host,
                        origin: aggregate.origin,
                        title: aggregate.title,
                        visits: aggregate.visits,
                        lastSeen: aggregate.lastSeen,
                        deepLinks: aggregate.deepLinks.map {
                            DeepLinkUpsert(url: $0.url, title: $0.title, visits: $0.visits)
                        }
                    )
                }
                try store.upsertHistory(upserts)

                if historyCollector.safariPermissionDenied {
                    reportFullDiskAccessOnce()
                }
            }

            if configuration.sync.chromeTabs && !tabsDisabled {
                do {
                    let tabs = try tabCollector.collect()
                    NSLog("EasyFind: captured %d tab(s) from Chrome", tabs.count)
                    let now = Int64(Date().timeIntervalSince1970)
                    for tab in tabs {
                        try store.upsertBookmark(url: tab.url, title: tab.title, lastSeen: now)
                    }
                } catch ChromeTabError.notAuthorized {
                    reportAutomationDeniedOnce()
                } catch {
                    NSLog("EasyFind: tab capture failed: \(error)")
                }
            }

            if configuration.sync.apps {
                let apps = AppScanner.scan()
                try store.replaceApps(apps)
                NSLog("EasyFind: indexed %d app(s)", apps.count)
            }

            if configuration.sync.folders {
                let folders = FolderHistoryScanner.scan()
                try store.replaceFolders(folders)
                NSLog("EasyFind: indexed %d folder(s)", folders.count)
            }

            let snapshot = try store.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.index.update(
                    entries: snapshot.entries,
                    deepLinks: snapshot.deepLinks,
                    apps: snapshot.apps,
                    folders: snapshot.folders
                )
                self.onUpdate?()
            }
        } catch {
            NSLog("EasyFind: sync failed: \(error)")
        }
    }

    private func reportAutomationDeniedOnce() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: "easyfind.automationHintShown") else { return }
            defaults.set(true, forKey: "easyfind.automationHintShown")

            let alert = NSAlert()
            alert.messageText = self.strings.automationTitle
            alert.informativeText = self.strings.automationInfo
            alert.addButton(withTitle: self.strings.openSettingsButton)
            alert.addButton(withTitle: self.strings.laterButton)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func reportFullDiskAccessOnce() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: "easyfind.fullDiskAccessHintShown") else { return }
            defaults.set(true, forKey: "easyfind.fullDiskAccessHintShown")

            let alert = NSAlert()
            alert.messageText = self.strings.fdaTitle
            alert.informativeText = self.strings.fdaInfo
            alert.addButton(withTitle: self.strings.openSettingsButton)
            alert.addButton(withTitle: self.strings.laterButton)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}