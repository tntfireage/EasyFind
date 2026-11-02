import Foundation

public enum BrowserFamily: Equatable {
    case chromium
    case firefox
    case safari
}

public struct BrowserHistorySource: Equatable {
    public let id: String
    public let name: String
    public let family: BrowserFamily
    /// A profile root for Chromium/Firefox, or the database file for Safari.
    public let root: URL

    public init(id: String, name: String, family: BrowserFamily, root: URL) {
        self.id = id
        self.name = name
        self.family = family
        self.root = root
    }
}

public enum BrowserHistoryDiscovery {
    public static func sources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserHistorySource] {
        let fileManager = FileManager.default
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var sources: [BrowserHistorySource] = []

        let chromiumRoots: [(id: String, name: String, relativePath: String)] = [
            ("chrome", "Google Chrome", "Google/Chrome"),
            ("chrome-beta", "Google Chrome Beta", "Google/Chrome Beta"),
            ("chrome-canary", "Google Chrome Canary", "Google/Chrome Canary"),
            ("chromium", "Chromium", "Chromium"),
            ("brave", "Brave", "BraveSoftware/Brave-Browser"),
            ("edge", "Microsoft Edge", "Microsoft Edge"),
            ("vivaldi", "Vivaldi", "Vivaldi"),
            ("opera", "Opera", "com.operasoftware.Opera"),
            ("arc", "Arc", "Arc/User Data"),
            ("sidekick", "Sidekick", "Sidekick")
        ]
        for entry in chromiumRoots {
            let root = appSupport.appendingPathComponent(entry.relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            sources.append(BrowserHistorySource(id: entry.id, name: entry.name, family: .chromium, root: root))
        }

        let firefoxRoots: [(id: String, name: String, relativePath: String)] = [
            ("firefox", "Firefox", "Firefox/Profiles"),
            ("firefox-developer", "Firefox Developer Edition", "Firefox Developer Edition/Profiles"),
            ("firefox-nightly", "Firefox Nightly", "Firefox Nightly/Profiles"),
            ("zen", "Zen", "zen/Profiles"),
            ("librewolf", "LibreWolf", "LibreWolf/Profiles")
        ]
        for entry in firefoxRoots {
            let root = appSupport.appendingPathComponent(entry.relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            sources.append(BrowserHistorySource(id: entry.id, name: entry.name, family: .firefox, root: root))
        }

        let safariDatabase = home.appendingPathComponent("Library/Safari/History.db")
        if fileManager.fileExists(atPath: safariDatabase.path) {
            sources.append(BrowserHistorySource(id: "safari", name: "Safari", family: .safari, root: safariDatabase))
        }

        let safariTechnologyPreview = home.appendingPathComponent(
            "Library/Containers/com.apple.SafariTechnologyPreview/Data/Library/Safari/History.db"
        )
        if fileManager.fileExists(atPath: safariTechnologyPreview.path) {
            sources.append(BrowserHistorySource(
                id: "safari-tp",
                name: "Safari Technology Preview",
                family: .safari,
                root: safariTechnologyPreview
            ))
        }

        // Deduplicate roots that resolve to the same path (symlinked app-support folders).
        var seen = Set<String>()
        return sources.filter { source in
            let canonical = source.root.resolvingSymlinksInPath().standardizedFileURL.path
            return seen.insert(canonical).inserted
        }
    }
}

public final class BrowserHistoryCollector {
    private struct ChromiumSource {
        let id: String
        let collector: ChromeHistoryCollector
    }

    private struct FirefoxSource {
        let id: String
        let collector: FirefoxHistoryCollector
    }

    private struct SafariSource {
        let id: String
        let collector: SafariHistoryCollector
    }

    private let chromiumSources: [ChromiumSource]
    private let firefoxSources: [FirefoxSource]
    private let safariSources: [SafariSource]

    public private(set) var safariPermissionDenied = false

    public init(sources: [BrowserHistorySource]) {
        var chromium: [ChromiumSource] = []
        var firefox: [FirefoxSource] = []
        var safari: [SafariSource] = []

        for source in sources {
            switch source.family {
            case .chromium:
                chromium.append(ChromiumSource(id: source.id, collector: ChromeHistoryCollector(root: source.root)))
            case .firefox:
                firefox.append(FirefoxSource(id: source.id, collector: FirefoxHistoryCollector(root: source.root)))
            case .safari:
                safari.append(SafariSource(
                    id: source.id,
                    collector: SafariHistoryCollector(databaseURL: source.root, label: source.name)
                ))
            }
        }

        chromiumSources = chromium
        firefoxSources = firefox
        safariSources = safari
    }

    /// Production discovery, or a single fixture source when `EASYFIND_CHROME_ROOT` is set.
    public convenience init() {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["EASYFIND_CHROME_ROOT"], !override.isEmpty {
            self.init(sources: [
                BrowserHistorySource(
                    id: "fixture",
                    name: "Fixture",
                    family: .chromium,
                    root: URL(fileURLWithPath: override, isDirectory: true)
                )
            ])
        } else {
            self.init(sources: BrowserHistoryDiscovery.sources())
        }
    }

    public func collect() -> [HostAggregate] {
        safariPermissionDenied = false
        var lists: [[HostAggregate]] = []

        for source in chromiumSources {
            do {
                let result = try source.collector.collect()
                NSLog("EasyFind: %@ history: %d host(s)", source.id, result.count)
                lists.append(result)
            } catch {
                NSLog("EasyFind: %@ history failed: %@", source.id, String(describing: error))
            }
        }

        for source in firefoxSources {
            let result = source.collector.collect()
            NSLog("EasyFind: %@ history: %d host(s)", source.id, result.count)
            lists.append(result)
        }

        for source in safariSources {
            let result = source.collector.collect()
            if source.collector.permissionDenied {
                safariPermissionDenied = true
            }
            NSLog("EasyFind: %@ history: %d host(s)", source.id, result.count)
            lists.append(result)
        }

        return HistoryMerger.merge(lists)
    }
}