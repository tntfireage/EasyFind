import Foundation

public enum FirefoxHistoryReader {
    public static func readRows(at path: String) throws -> [ChromeHistoryRow] {
        let database = try SQLiteDatabase(path: path)
        let statement = try database.prepare("""
        SELECT url, title, visit_count, last_visit_date
          FROM moz_places
         WHERE visit_count > 0 AND url IS NOT NULL
        """)

        var rows: [ChromeHistoryRow] = []
        while try statement.step() {
            guard let url = statement.text(0), !url.isEmpty else { continue }
            let microseconds = statement.int64(3)
            let lastVisit = microseconds > 0 ? microseconds / 1_000_000 : 0
            rows.append(ChromeHistoryRow(
                url: url,
                title: statement.text(1),
                visitCount: statement.int(2),
                lastVisitTime: lastVisit
            ))
        }
        return rows
    }
}

public final class FirefoxHistoryCollector {
    private let root: URL
    private let snapshotter: ChromeHistorySnapshotter
    private var cache: [String: [HostAggregate]] = [:]
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("easyfind-firefox-\(UUID().uuidString)", isDirectory: true)
        snapshotter = ChromeHistorySnapshotter(tempRoot: tempRoot)
    }

    public func collect() -> [HostAggregate] {
        lock.lock()
        defer { lock.unlock() }

        let profiles = Self.profiles(root: root)
        var lists: [[HostAggregate]] = []

        for profile in profiles {
            if !snapshotter.refreshNeeded(for: profile), let cached = cache[profile.name] {
                lists.append(cached)
                continue
            }
            do {
                let snapshot = try snapshotter.makeSnapshot(for: profile)
                let rows = try FirefoxHistoryReader.readRows(at: snapshot.path)
                let aggregates = HistoryAggregator.aggregate(rows)
                cache[profile.name] = aggregates
                lists.append(aggregates)
            } catch {
                snapshotter.invalidate(profile)
                if let cached = cache[profile.name] {
                    lists.append(cached)
                }
            }
        }

        snapshotter.removeAllSnapshots()
        return HistoryMerger.merge(lists)
    }

    static func profiles(root: URL) -> [ChromeProfile] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var profiles: [ChromeProfile] = []
        for child in children {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let database = child.appendingPathComponent("places.sqlite")
            guard fileManager.fileExists(atPath: database.path) else { continue }
            profiles.append(ChromeProfile(
                name: child.lastPathComponent,
                historyURL: database,
                walURL: child.appendingPathComponent("places.sqlite-wal"),
                shmURL: child.appendingPathComponent("places.sqlite-shm")
            ))
        }
        return profiles.sorted { $0.name < $1.name }
    }
}