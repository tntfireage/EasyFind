import Foundation
@testable import EasyFindCore

struct FixtureRow {
    let url: String
    let title: String
    let visits: Int
    let unixTime: Int64

    init(url: String, title: String = "", visits: Int = 0, unixTime: Int64 = 1_600_000_000) {
        self.url = url
        self.title = title
        self.visits = visits
        self.unixTime = unixTime
    }
}

struct FirefoxFixtureRow {
    let url: String
    let title: String
    let visits: Int
    let lastVisitMicros: Int64

    init(url: String, title: String = "", visits: Int = 0, lastVisitMicros: Int64 = 0) {
        self.url = url
        self.title = title
        self.visits = visits
        self.lastVisitMicros = lastVisitMicros
    }
}

struct SafariFixtureVisit {
    let title: String?
    let time: Double
}

struct SafariFixtureItem {
    let url: String
    let visitCount: Int
    let visits: [SafariFixtureVisit]
}

enum TestSupport {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("easyfind-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeStore() throws -> (Store, URL) {
        let directory = try temporaryDirectory()
        let store = try Store(path: directory.appendingPathComponent("easyfind.db").path)
        return (store, directory)
    }

    static func chromiumMicros(unixTime: Int64) -> Int64 {
        (unixTime + ChromiumTime.epochOffsetSeconds) * 1_000_000
    }

    /// Creates a minimal `.app` bundle that `Bundle` can read.
    static func makeAppBundle(
        at url: URL,
        name: String,
        bundleID: String?,
        displayName: String? = nil,
        bundleName: String? = nil,
        executable: Bool = true
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        if executable {
            let executableURL = macOS.appendingPathComponent(name)
            FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: executableURL.path
            )
        }

        var info: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleName": bundleName ?? name,
            "CFBundleExecutable": name
        ]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let displayName { info["CFBundleDisplayName"] = displayName }

        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// Creates a minimal SQLite file that looks like Chrome's `History` database.
    static func makeChromeProfileDatabase(at historyURL: URL, rows: [FixtureRow]) throws {
        let directory = historyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let database = try SQLiteDatabase(path: historyURL.path)
        try database.exec("""
        CREATE TABLE urls (
            id INTEGER PRIMARY KEY,
            url TEXT,
            title TEXT,
            visit_count INTEGER,
            last_visit_time INTEGER
        );
        """)
        for (offset, row) in rows.enumerated() {
            let statement = try database.prepare(
                "INSERT INTO urls (id, url, title, visit_count, last_visit_time) VALUES (?, ?, ?, ?, ?)"
            )
            statement.bind(1, offset + 1)
            statement.bind(2, row.url)
            statement.bind(3, row.title)
            statement.bind(4, row.visits)
            statement.bind(5, chromiumMicros(unixTime: row.unixTime))
            _ = try statement.step()
        }
        try database.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Creates a minimal Firefox `places.sqlite`.
    static func makeFirefoxProfileDatabase(at url: URL, rows: [FirefoxFixtureRow]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDatabase(path: url.path)
        try database.exec("""
        CREATE TABLE moz_places (
            id INTEGER PRIMARY KEY,
            url TEXT,
            title TEXT,
            visit_count INTEGER,
            last_visit_date INTEGER
        );
        """)
        for (offset, row) in rows.enumerated() {
            let statement = try database.prepare("""
            INSERT INTO moz_places (id, url, title, visit_count, last_visit_date)
            VALUES (?, ?, ?, ?, ?)
            """)
            statement.bind(1, offset + 1)
            statement.bind(2, row.url)
            statement.bind(3, row.title)
            statement.bind(4, row.visits)
            statement.bind(5, row.lastVisitMicros)
            _ = try statement.step()
        }
        try database.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Creates a minimal Safari `History.db` with titles on visits.
    static func makeSafariHistoryDatabase(at url: URL, items: [SafariFixtureItem]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDatabase(path: url.path)
        try database.exec("""
        CREATE TABLE history_items (
            id INTEGER PRIMARY KEY,
            url TEXT,
            visit_count INTEGER
        );
        CREATE TABLE history_visits (
            id INTEGER PRIMARY KEY,
            history_item INTEGER,
            visit_time REAL,
            title TEXT
        );
        """)

        var visitID = 1
        for (offset, item) in items.enumerated() {
            let itemID = offset + 1
            let itemStatement = try database.prepare(
                "INSERT INTO history_items (id, url, visit_count) VALUES (?, ?, ?)"
            )
            itemStatement.bind(1, itemID)
            itemStatement.bind(2, item.url)
            itemStatement.bind(3, item.visitCount)
            _ = try itemStatement.step()

            for visit in item.visits {
                let visitStatement = try database.prepare(
                    "INSERT INTO history_visits (id, history_item, visit_time, title) VALUES (?, ?, ?, ?)"
                )
                visitStatement.bind(1, visitID)
                visitStatement.bind(2, itemID)
                visitStatement.bind(3, visit.time)
                visitStatement.bind(4, visit.title)
                _ = try visitStatement.step()
                visitID += 1
            }
        }
        try database.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Older Safari schema without a title column on visits.
    static func makeSafariHistoryDatabaseWithoutTitles(at url: URL, urls: [String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDatabase(path: url.path)
        try database.exec("""
        CREATE TABLE history_items (
            id INTEGER PRIMARY KEY,
            url TEXT,
            visit_count INTEGER
        );
        CREATE TABLE history_visits (
            id INTEGER PRIMARY KEY,
            history_item INTEGER,
            visit_time REAL
        );
        """)
        for (offset, rawURL) in urls.enumerated() {
            let itemID = offset + 1
            let itemStatement = try database.prepare(
                "INSERT INTO history_items (id, url, visit_count) VALUES (?, ?, ?)"
            )
            itemStatement.bind(1, itemID)
            itemStatement.bind(2, rawURL)
            itemStatement.bind(3, 2)
            _ = try itemStatement.step()

            let visitStatement = try database.prepare(
                "INSERT INTO history_visits (id, history_item, visit_time) VALUES (?, ?, ?)"
            )
            visitStatement.bind(1, itemID)
            visitStatement.bind(2, itemID)
            visitStatement.bind(3, 0.0)
            _ = try visitStatement.step()
        }
        try database.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}

func makeEntry(
    id: Int64,
    kind: EntryKind = .bookmark,
    host: String,
    url: String? = nil,
    title: String? = nil,
    alias: String? = nil,
    visits: Int = 0,
    lastSeen: Int64 = 0
) -> Entry {
    Entry(
        id: id,
        kind: kind,
        host: host,
        origin: url.flatMap(URLTools.origin(of:)),
        url: url,
        title: title,
        alias: alias,
        visits: visits,
        ownOpens: 0,
        lastSeen: lastSeen
    )
}