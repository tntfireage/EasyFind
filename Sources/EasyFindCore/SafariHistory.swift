import Darwin
import Foundation

public enum BrowserHistoryError {
    public static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }
}

public enum SafariHistoryReader {
    /// Seconds between 2001-01-01 (Safari's epoch) and 1970-01-01.
    public static let epochOffsetSeconds: Int64 = 978_307_200

    public static func readRows(at path: String) throws -> [ChromeHistoryRow] {
        let database = try SQLiteDatabase(path: path)

        if let statement = try? database.prepare(primaryQuery) {
            return try readRows(from: statement)
        }

        // Older schema without history_visits.title.
        let fallback = try database.prepare("""
        SELECT url, NULL, visit_count, 0
          FROM history_items
         WHERE visit_count > 0 AND url IS NOT NULL
        """)
        return try readRows(from: fallback)
    }

    private static let primaryQuery = """
    SELECT i.url,
           (SELECT v.title FROM history_visits v
             WHERE v.history_item = i.id AND v.title IS NOT NULL AND length(v.title) > 0
             ORDER BY v.visit_time DESC LIMIT 1),
           i.visit_count,
           (SELECT MAX(v.visit_time) FROM history_visits v WHERE v.history_item = i.id)
      FROM history_items i
     WHERE i.visit_count > 0 AND i.url IS NOT NULL
    """

    private static func readRows(from statement: SQLiteStatement) throws -> [ChromeHistoryRow] {
        var rows: [ChromeHistoryRow] = []
        while try statement.step() {
            guard let url = statement.text(0), !url.isEmpty else { continue }
            let seconds = statement.double(3)
            let lastVisit = seconds > 0 ? Int64(seconds.rounded()) + epochOffsetSeconds : 0
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

public final class SafariHistoryCollector {
    private let profile: ChromeProfile
    private let snapshotter: ChromeHistorySnapshotter
    private var cache: [HostAggregate]?
    private let lock = NSLock()
    public private(set) var permissionDenied = false

    public init(databaseURL: URL, label: String) {
        profile = ChromeProfile(
            name: label,
            historyURL: databaseURL,
            walURL: URL(fileURLWithPath: databaseURL.path + "-wal"),
            shmURL: URL(fileURLWithPath: databaseURL.path + "-shm")
        )
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("easyfind-safari-\(UUID().uuidString)", isDirectory: true)
        snapshotter = ChromeHistorySnapshotter(tempRoot: tempRoot)
    }

    public func collect() -> [HostAggregate] {
        lock.lock()
        defer { lock.unlock() }
        defer { snapshotter.removeAllSnapshots() }

        if !snapshotter.refreshNeeded(for: profile), let cache {
            return cache
        }

        do {
            let snapshot = try snapshotter.makeSnapshot(for: profile)
            let rows = try SafariHistoryReader.readRows(at: snapshot.path)
            let aggregates = HistoryAggregator.aggregate(rows)
            cache = aggregates
            permissionDenied = false
            return aggregates
        } catch {
            snapshotter.invalidate(profile)
            if BrowserHistoryError.isPermissionDenied(error) {
                permissionDenied = true
                NSLog("EasyFind: Safari history requires Full Disk Access")
            } else {
                NSLog("EasyFind: Safari history read failed: \(error)")
            }
            return cache ?? []
        }
    }
}