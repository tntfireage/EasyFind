import XCTest
@testable import EasyFindCore

final class StoreTests: XCTestCase {
    func testJournalModeAndPermissions() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(try store.journalMode(), "wal")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode, 0o600)
    }

    func testMigrationIsIdempotent() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("easyfind.db").path

        _ = try Store(path: path)
        let reopened = try Store(path: path)
        XCTAssertNoThrow(try reopened.snapshot())
    }

    func testHistoryAggregatesToOneRowPerHost() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.upsertHistory([
            HistoryUpsert(host: "github.com", origin: "https://github.com", title: "GitHub",
                          visits: 20, lastSeen: 100, deepLinks: [])
        ])
        try store.upsertHistory([
            HistoryUpsert(host: "github.com", origin: "https://github.com", title: "GitHub",
                          visits: 5, lastSeen: 200, deepLinks: [])
        ])

        let history = try store.snapshot().entries.filter { $0.kind == .history }
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.visits, 20)
        XCTAssertEqual(history.first?.lastSeen, 200)
    }

    func testVisitsNeverDecrease() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.upsertHistory([
            HistoryUpsert(host: "github.com", origin: "https://github.com", title: "GitHub",
                          visits: 10, lastSeen: 100, deepLinks: [])
        ])
        try store.upsertHistory([
            HistoryUpsert(host: "github.com", origin: "https://github.com", title: "GitHub",
                          visits: 3, lastSeen: 50, deepLinks: [])
        ])

        let history = try store.snapshot().entries.filter { $0.kind == .history }
        XCTAssertEqual(history.first?.visits, 10)
    }

    func testBookmarksDedupeByURLAndRefreshTitle() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.upsertBookmark(url: "https://example.com/a", title: "First", lastSeen: 1)
        try store.upsertBookmark(url: "https://example.com/a", title: "Second", lastSeen: 2)

        let bookmarks = try store.snapshot().entries.filter { $0.kind == .bookmark }
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.title, "Second")
    }

    func testManualEntryUpdatesAliasInsteadOfDuplicating() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try store.addManual(url: "example.com/docs", alias: "A")
        _ = try store.addManual(url: "https://example.com/docs", alias: "B")

        let manual = try store.snapshot().entries.filter { $0.kind == .manual }
        XCTAssertEqual(manual.count, 1)
        XCTAssertEqual(manual.first?.alias, "B")
    }

    func testSavingExistingBookmarkURLPromotesItToManualEntry() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.upsertBookmark(url: "https://example.com/a", title: "A", lastSeen: 1)
        _ = try store.addManual(url: "https://example.com/a", alias: "Mine")

        let entries = try store.snapshot().entries.filter { $0.url == "https://example.com/a" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .manual)
        XCTAssertEqual(entries.first?.alias, "Mine")
    }

    func testManualEntryPersistsAcrossReopen() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("easyfind.db").path

        do {
            let store = try Store(path: path)
            _ = try store.addManual(url: "https://example.com/docs", alias: "API 文档")
        }

        let reopened = try Store(path: path)
        let entries = try reopened.snapshot().entries
        XCTAssertTrue(entries.contains {
            $0.kind == .manual && $0.alias == "API 文档" && $0.url == "https://example.com/docs"
        })
    }

    func testOpenTargetUsesOriginForHistoryAndURLForManualEntries() {
        let history = Entry(
            id: 1, kind: .history, host: "example.com", origin: "http://example.com",
            url: nil, title: nil, alias: nil, visits: 0, ownOpens: 0, lastSeen: 0
        )
        XCTAssertEqual(history.openTarget, "http://example.com")

        let manual = makeEntry(
            id: 2, kind: .manual, host: "example.com",
            url: "https://example.com/docs", title: "Docs"
        )
        XCTAssertEqual(manual.openTarget, "https://example.com/docs")

        let bookmark = makeEntry(
            id: 3, kind: .bookmark, host: "example.com",
            url: "https://example.com/tab", title: "Tab"
        )
        XCTAssertEqual(bookmark.openTarget, "https://example.com/tab")

        let app = Entry(
            id: 4, kind: .app, host: "safari", origin: nil,
            url: "/Applications/Safari.app", title: "Safari", alias: nil,
            visits: 0, ownOpens: 0, lastSeen: 0
        )
        XCTAssertEqual(app.openTarget, "/Applications/Safari.app")
    }

    func testAppCatalogSweepsRemovedAppsAndPreservesOpenCounts() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let alpha = InstalledApp(bundleID: "com.example.alpha", name: "Alpha", path: "/Applications/Alpha.app")
        let beta = InstalledApp(bundleID: "com.example.beta", name: "Beta", path: "/Applications/Beta.app")
        try store.replaceApps([alpha, beta])

        let first = try store.snapshot().apps
        XCTAssertEqual(first.count, 2)
        let alphaID = try XCTUnwrap(first.first { $0.bundleID == "com.example.alpha" }?.id)
        try store.recordAppOpen(id: alphaID)

        try store.replaceApps([alpha])

        let second = try store.snapshot().apps
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.name, "Alpha")
        XCTAssertEqual(second.first?.ownOpens, 1)
    }

    func testAppCatalogMovesBundleWithoutResettingOpens() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.replaceApps([
            InstalledApp(bundleID: "com.example.app", name: "Example", path: "/Applications/Example.app")
        ])
        let id = try XCTUnwrap(try store.snapshot().apps.first?.id)
        try store.recordAppOpen(id: id)

        try store.replaceApps([
            InstalledApp(bundleID: "com.example.app", name: "Example", path: "/Applications/Utilities/Example.app")
        ])

        let apps = try store.snapshot().apps
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.path, "/Applications/Utilities/Example.app")
        XCTAssertEqual(apps.first?.ownOpens, 1)
    }

    func testMigrationFromV2AddsFoldersTableAndKeepsData() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("easyfind.db").path

        do {
            let legacy = try SQLiteDatabase(path: path)
            try legacy.exec("""
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                host TEXT NOT NULL,
                origin TEXT,
                url TEXT,
                title TEXT,
                alias TEXT,
                visits INTEGER NOT NULL DEFAULT 0,
                own_opens INTEGER NOT NULL DEFAULT 0,
                last_seen INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE deep_links (
                host TEXT NOT NULL,
                url TEXT NOT NULL,
                title TEXT,
                visits INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE apps (
                id INTEGER PRIMARY KEY,
                bundle_id TEXT,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                own_opens INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            INSERT INTO entries (kind, host, origin, url, title, alias, visits, own_opens, last_seen, created_at, updated_at)
            VALUES ('history', 'legacy.example', 'https://legacy.example', NULL, 'Legacy', NULL, 7, 0, 0, 0, 0);
            INSERT INTO apps (bundle_id, name, path, own_opens, created_at, updated_at)
            VALUES ('com.example.app', 'Example', '/Applications/Example.app', 0, 0, 0);
            """)
            try legacy.setUserVersion(2)
        }

        let store = try Store(path: path)
        XCTAssertEqual(try store.schemaVersion(), 3)
        XCTAssertTrue(try store.snapshot().entries.contains { $0.host == "legacy.example" })
        XCTAssertTrue(try store.snapshot().apps.contains { $0.name == "Example" })

        let folder = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.replaceFolders([
            folderCandidate(path: folder.path, visits: 1, lastSeen: 1, sources: ["shell"])
        ])
        XCTAssertEqual(try store.snapshot().folders.count, 1)
    }

    func testFolderCatalogDeduplicatesAndPreservesOpenCounts() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let alpha = directory.appendingPathComponent("alpha", isDirectory: true)
        let beta = directory.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)

        try store.replaceFolders([
            folderCandidate(path: alpha.path, visits: 2, lastSeen: 100, sources: ["shell"]),
            folderCandidate(path: alpha.path, visits: 5, lastSeen: 200, sources: ["cursor"]),
            folderCandidate(path: beta.path, visits: 1, lastSeen: 50, sources: ["finder"])
        ])

        var folders = try store.snapshot().folders
        XCTAssertEqual(folders.count, 2)
        let alphaEntry = try XCTUnwrap(folders.first { $0.path == alpha.resolvingSymlinksInPath().path })
        XCTAssertEqual(alphaEntry.visits, 5)
        XCTAssertEqual(alphaEntry.lastSeen, 200)
        XCTAssertEqual(alphaEntry.sources, ["cursor", "shell"])

        try store.recordFolderOpen(id: alphaEntry.id)
        try store.replaceFolders([
            folderCandidate(path: alpha.path, visits: 1, lastSeen: 300, sources: ["shell"])
        ])
        folders = try store.snapshot().folders
        let refreshed = try XCTUnwrap(folders.first { $0.path == alpha.resolvingSymlinksInPath().path })
        XCTAssertEqual(refreshed.ownOpens, 1)
        XCTAssertEqual(refreshed.visits, 5)

        try store.clearFolders()
        XCTAssertTrue(try store.snapshot().folders.isEmpty)
    }

    func testFolderSnapshotFiltersMissingDirectories() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let missing = directory.appendingPathComponent("missing", isDirectory: true)

        try store.replaceFolders([
            folderCandidate(path: existing.path, visits: 1, lastSeen: 1, sources: ["shell"]),
            folderCandidate(path: missing.path, visits: 1, lastSeen: 1, sources: ["shell"])
        ])

        let folders = try store.snapshot().folders
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.path, existing.resolvingSymlinksInPath().path)
    }

    func testFolderCatalogExcludesPackages() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = directory.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        try store.replaceFolders([
            folderCandidate(path: package.path, visits: 1, lastSeen: 1, sources: ["finder"])
        ])

        XCTAssertTrue(try store.snapshot().folders.isEmpty)
    }

    private func folderCandidate(path: String, visits: Int, lastSeen: Int64, sources: [String]) -> FolderCandidate {
        FolderCandidate(
            key: path.lowercased(),
            path: path,
            name: (path as NSString).lastPathComponent,
            visits: visits,
            lastSeen: lastSeen,
            sources: sources
        )
    }

    func testMigrationFromV1AddsAppsTableAndKeepsEntries() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("easyfind.db").path

        do {
            let legacy = try SQLiteDatabase(path: path)
            try legacy.exec("""
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                host TEXT NOT NULL,
                origin TEXT,
                url TEXT,
                title TEXT,
                alias TEXT,
                visits INTEGER NOT NULL DEFAULT 0,
                own_opens INTEGER NOT NULL DEFAULT 0,
                last_seen INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE deep_links (
                host TEXT NOT NULL,
                url TEXT NOT NULL,
                title TEXT,
                visits INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO entries (kind, host, origin, url, title, alias, visits, own_opens, last_seen, created_at, updated_at)
            VALUES ('history', 'legacy.example', 'https://legacy.example', NULL, 'Legacy', NULL, 7, 0, 0, 0, 0);
            """)
            try legacy.setUserVersion(1)
        }

        let store = try Store(path: path)
        XCTAssertEqual(try store.schemaVersion(), 3)
        XCTAssertTrue(try store.snapshot().entries.contains { $0.host == "legacy.example" })

        try store.replaceApps([
            InstalledApp(bundleID: "com.example.alpha", name: "Alpha", path: "/Applications/Alpha.app")
        ])
        XCTAssertEqual(try store.snapshot().apps.count, 1)
    }
}