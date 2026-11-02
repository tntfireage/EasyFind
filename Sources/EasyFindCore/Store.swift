import Foundation

public final class Store {
    public let path: String
    private let db: SQLiteDatabase
    private let queue = DispatchQueue(label: "com.easyfind.store")

    public init(path: String) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory
            )
        }
        db = try SQLiteDatabase(path: path)
        try db.exec("PRAGMA journal_mode=WAL;")
        try db.exec("PRAGMA busy_timeout=5000;")
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                               ofItemAtPath: path)
        try migrate()
    }

    private func migrate() throws {
        let version = try db.userVersion()
        if version < 1 {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS entries (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL CHECK (kind IN ('history', 'bookmark', 'manual')),
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
            CREATE UNIQUE INDEX IF NOT EXISTS ux_entries_history_host
                ON entries(host) WHERE kind = 'history';
            CREATE UNIQUE INDEX IF NOT EXISTS ux_entries_url
                ON entries(url) WHERE kind IN ('bookmark', 'manual') AND url IS NOT NULL;
            CREATE INDEX IF NOT EXISTS ix_entries_visits ON entries(visits DESC);

            CREATE TABLE IF NOT EXISTS deep_links (
                host TEXT NOT NULL,
                url TEXT NOT NULL,
                title TEXT,
                visits INTEGER NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX IF NOT EXISTS ux_deep_links_host_url ON deep_links(host, url);
            """)
            try db.setUserVersion(1)
        }
        if version < 2 {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS apps (
                id INTEGER PRIMARY KEY,
                bundle_id TEXT,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                own_opens INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS ux_apps_bundle_id
                ON apps(bundle_id) WHERE bundle_id IS NOT NULL;
            """)
            try db.setUserVersion(2)
        }
        if version < 3 {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS folders (
                id INTEGER PRIMARY KEY,
                path_key TEXT NOT NULL UNIQUE,
                path TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                visits INTEGER NOT NULL DEFAULT 0,
                own_opens INTEGER NOT NULL DEFAULT 0,
                last_seen INTEGER NOT NULL DEFAULT 0,
                sources TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            """)
            try db.setUserVersion(3)
        }
    }

    // MARK: - Writes

    public func upsertHistory(_ items: [HistoryUpsert]) throws {
        try queue.sync {
            try inTransaction {
                for item in items {
                    try upsertHistoryLocked(item)
                }
            }
        }
    }

    private func upsertHistoryLocked(_ item: HistoryUpsert) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let select = try db.prepare("SELECT id, origin, title, visits, last_seen FROM entries WHERE kind = 'history' AND host = ?")
        select.bind(1, item.host)
        if try select.step() {
            let id = select.int64(0)
            let existingOrigin = select.text(1)
            let existingTitle = select.text(2)
            let existingVisits = select.int(3)
            let existingLastSeen = select.int64(4)

            let origin = item.origin.isEmpty ? (existingOrigin ?? item.origin) : item.origin
            let title = (item.title?.isEmpty == false ? item.title : existingTitle)
            let visits = max(existingVisits, item.visits)
            let lastSeen = max(existingLastSeen, item.lastSeen)

            let update = try db.prepare("""
            UPDATE entries
               SET origin = ?, title = ?, visits = ?, last_seen = ?, updated_at = ?
             WHERE id = ?
            """)
            update.bind(1, origin)
            update.bind(2, title)
            update.bind(3, visits)
            update.bind(4, lastSeen)
            update.bind(5, now)
            update.bind(6, id)
            _ = try update.step()
        } else {
            let insert = try db.prepare("""
            INSERT INTO entries (kind, host, origin, url, title, alias, visits, own_opens, last_seen, created_at, updated_at)
            VALUES ('history', ?, ?, NULL, ?, NULL, ?, 0, ?, ?, ?)
            """)
            insert.bind(1, item.host)
            insert.bind(2, item.origin)
            insert.bind(3, item.title)
            insert.bind(4, item.visits)
            insert.bind(5, item.lastSeen)
            insert.bind(6, now)
            insert.bind(7, now)
            _ = try insert.step()
        }

        for link in item.deepLinks {
            let upsert = try db.prepare("""
            INSERT INTO deep_links (host, url, title, visits) VALUES (?, ?, ?, ?)
            ON CONFLICT(host, url) DO UPDATE SET
                title = excluded.title,
                visits = MAX(deep_links.visits, excluded.visits)
            """)
            upsert.bind(1, item.host)
            upsert.bind(2, link.url)
            upsert.bind(3, link.title)
            upsert.bind(4, link.visits)
            _ = try upsert.step()
        }
    }

    @discardableResult
    public func upsertBookmark(url: String, title: String?, lastSeen: Int64) throws -> Bool {
        guard let host = URLTools.host(of: url), let origin = URLTools.origin(of: url) else { return false }
        return try queue.sync {
            try inTransaction {
                try upsertBookmarkLocked(url: url, host: host, origin: origin, title: title, lastSeen: lastSeen)
            }
            return true
        }
    }

    private func upsertBookmarkLocked(url: String, host: String, origin: String, title: String?, lastSeen: Int64) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let select = try db.prepare("SELECT id, title, last_seen FROM entries WHERE url = ?")
        select.bind(1, url)
        if try select.step() {
            let id = select.int64(0)
            let existingTitle = select.text(1)
            let existingLastSeen = select.int64(2)
            let mergedTitle = (title?.isEmpty == false ? title : existingTitle)
            let update = try db.prepare("UPDATE entries SET title = ?, last_seen = ?, updated_at = ? WHERE id = ?")
            update.bind(1, mergedTitle)
            update.bind(2, max(existingLastSeen, lastSeen))
            update.bind(3, now)
            update.bind(4, id)
            _ = try update.step()
        } else {
            let insert = try db.prepare("""
            INSERT INTO entries (kind, host, origin, url, title, alias, visits, own_opens, last_seen, created_at, updated_at)
            VALUES ('bookmark', ?, ?, ?, ?, NULL, 0, 0, ?, ?, ?)
            """)
            insert.bind(1, host)
            insert.bind(2, origin)
            insert.bind(3, url)
            insert.bind(4, title)
            insert.bind(5, lastSeen)
            insert.bind(6, now)
            insert.bind(7, now)
            _ = try insert.step()
        }
    }

    @discardableResult
    public func addManual(url rawURL: String, alias: String?) throws -> Int64? {
        guard let url = URLTools.normalizedURLString(rawURL),
              let host = URLTools.host(of: url),
              let origin = URLTools.origin(of: url) else { return nil }
        return try queue.sync {
            try inTransaction {
                let now = Int64(Date().timeIntervalSince1970)
                let select = try db.prepare("SELECT id FROM entries WHERE url = ?")
                select.bind(1, url)
                if try select.step() {
                    let id = select.int64(0)
                    let update = try db.prepare("UPDATE entries SET alias = ?, kind = 'manual', last_seen = ?, updated_at = ? WHERE id = ?")
                    update.bind(1, alias?.isEmpty == true ? nil : alias)
                    update.bind(2, now)
                    update.bind(3, now)
                    update.bind(4, id)
                    _ = try update.step()
                    return id
                }

                let insert = try db.prepare("""
                INSERT INTO entries (kind, host, origin, url, title, alias, visits, own_opens, last_seen, created_at, updated_at)
                VALUES ('manual', ?, ?, ?, NULL, ?, 0, 0, ?, ?, ?)
                """)
                insert.bind(1, host)
                insert.bind(2, origin)
                insert.bind(3, url)
                insert.bind(4, alias?.isEmpty == true ? nil : alias)
                insert.bind(5, now)
                insert.bind(6, now)
                insert.bind(7, now)
                _ = try insert.step()

                let idStatement = try db.prepare("SELECT last_insert_rowid()")
                _ = try idStatement.step()
                return idStatement.int64(0)
            }
        }
    }

    public func recordOpen(id: Int64) throws {
        try queue.sync {
            let now = Int64(Date().timeIntervalSince1970)
            let update = try db.prepare("UPDATE entries SET own_opens = own_opens + 1, last_seen = MAX(last_seen, ?), updated_at = ? WHERE id = ?")
            update.bind(1, now)
            update.bind(2, now)
            update.bind(3, id)
            _ = try update.step()
        }
    }

    // MARK: - Applications

    /// Rebuilds the app catalog: upserts scanned apps and removes bundles that vanished.
    /// Open counts of surviving apps are preserved.
    public func replaceApps(_ apps: [InstalledApp]) throws {
        try queue.sync {
            try inTransaction {
                struct ExistingApp {
                    let id: Int64
                    let bundleID: String?
                    let path: String
                }

                var existing: [ExistingApp] = []
                let select = try db.prepare("SELECT id, bundle_id, path FROM apps")
                while try select.step() {
                    existing.append(ExistingApp(
                        id: select.int64(0),
                        bundleID: select.text(1),
                        path: select.text(2) ?? ""
                    ))
                }

                var byPath: [String: Int64] = [:]
                var byBundle: [String: Int64] = [:]
                for row in existing {
                    byPath[row.path] = row.id
                    if let bundleID = row.bundleID {
                        byBundle[bundleID] = row.id
                    }
                }

                let now = Int64(Date().timeIntervalSince1970)
                var kept = Set<Int64>()

                for app in apps {
                    var match = byPath[app.path]
                    if match == nil, let bundleID = app.bundleID {
                        match = byBundle[bundleID]
                    }

                    if let id = match {
                        let update = try db.prepare("""
                        UPDATE apps SET bundle_id = ?, name = ?, path = ?, updated_at = ? WHERE id = ?
                        """)
                        update.bind(1, app.bundleID)
                        update.bind(2, app.name)
                        update.bind(3, app.path)
                        update.bind(4, now)
                        update.bind(5, id)
                        _ = try update.step()
                        kept.insert(id)
                    } else {
                        let insert = try db.prepare("""
                        INSERT INTO apps (bundle_id, name, path, own_opens, created_at, updated_at)
                        VALUES (?, ?, ?, 0, ?, ?)
                        """)
                        insert.bind(1, app.bundleID)
                        insert.bind(2, app.name)
                        insert.bind(3, app.path)
                        insert.bind(4, now)
                        insert.bind(5, now)
                        _ = try insert.step()

                        let idStatement = try db.prepare("SELECT last_insert_rowid()")
                        _ = try idStatement.step()
                        kept.insert(idStatement.int64(0))
                    }
                }

                for row in existing where !kept.contains(row.id) {
                    let delete = try db.prepare("DELETE FROM apps WHERE id = ?")
                    delete.bind(1, row.id)
                    _ = try delete.step()
                }
            }
        }
    }
    public func recordAppOpen(id: Int64) throws {
        try queue.sync {
            let update = try db.prepare("UPDATE apps SET own_opens = own_opens + 1, updated_at = ? WHERE id = ?")
            update.bind(1, Int64(Date().timeIntervalSince1970))
            update.bind(2, id)
            _ = try update.step()
        }
    }

    // MARK: - Folders

    /// Upserts the scanned folder catalog. Existing rows keep their open counts and
    /// are never removed by a refresh (missing directories are filtered at read time).
    public func replaceFolders(_ folders: [FolderCandidate]) throws {
        try queue.sync {
            try inTransaction {
                let now = Int64(Date().timeIntervalSince1970)
                for folder in folders {
                    let select = try db.prepare("""
                    SELECT id, visits, last_seen, sources FROM folders WHERE path_key = ? OR path = ?
                    """)
                    select.bind(1, folder.key)
                    select.bind(2, folder.path)

                    if try select.step() {
                        let id = select.int64(0)
                        let visits = max(select.int(1), folder.visits)
                        let lastSeen = max(select.int64(2), folder.lastSeen)
                        let sources = Self.mergedSources(existing: select.text(3), adding: folder.sources)

                        let update = try db.prepare("""
                        UPDATE folders
                           SET path_key = ?, path = ?, name = ?, visits = ?, last_seen = ?, sources = ?, updated_at = ?
                         WHERE id = ?
                        """)
                        update.bind(1, folder.key)
                        update.bind(2, folder.path)
                        update.bind(3, folder.name)
                        update.bind(4, visits)
                        update.bind(5, lastSeen)
                        update.bind(6, sources)
                        update.bind(7, now)
                        update.bind(8, id)
                        _ = try update.step()
                    } else {
                        let insert = try db.prepare("""
                        INSERT INTO folders (path_key, path, name, visits, own_opens, last_seen, sources, created_at, updated_at)
                        VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)
                        """)
                        insert.bind(1, folder.key)
                        insert.bind(2, folder.path)
                        insert.bind(3, folder.name)
                        insert.bind(4, folder.visits)
                        insert.bind(5, folder.lastSeen)
                        insert.bind(6, folder.sources.sorted().joined(separator: ","))
                        insert.bind(7, now)
                        insert.bind(8, now)
                        _ = try insert.step()
                    }
                }

                // Prune rows that still exist but are packages (`.app`, saved searches)
                // rather than plain folders. Missing directories are kept so an
                // unmounted volume can reappear later.
                var pruneIDs: [Int64] = []
                let existing = try db.prepare("SELECT id, path FROM folders")
                while try existing.step() {
                    let id = existing.int64(0)
                    let path = existing.text(1) ?? ""
                    if FileManager.default.fileExists(atPath: path),
                       FolderHistoryScanner.canonicalDirectory(path) == nil {
                        pruneIDs.append(id)
                    }
                }
                for id in pruneIDs {
                    let delete = try db.prepare("DELETE FROM folders WHERE id = ?")
                    delete.bind(1, id)
                    _ = try delete.step()
                }
            }
        }
    }

    public func recordFolderOpen(id: Int64) throws {
        try queue.sync {
            let update = try db.prepare("UPDATE folders SET own_opens = own_opens + 1, updated_at = ? WHERE id = ?")
            update.bind(1, Int64(Date().timeIntervalSince1970))
            update.bind(2, id)
            _ = try update.step()
        }
    }

    public func clearFolders() throws {
        try queue.sync {
            try db.exec("DELETE FROM folders")
        }
    }

    private static func mergedSources(existing: String?, adding: [String]) -> String {
        var set = Set<String>()
        if let existing {
            for part in existing.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { set.insert(trimmed) }
            }
        }
        for source in adding where !source.isEmpty {
            set.insert(source)
        }
        return set.sorted().joined(separator: ",")
    }

    // MARK: - Reads

    public func snapshot() throws -> StoreSnapshot {
        try queue.sync {
            var entries: [Entry] = []
            let select = try db.prepare("""
            SELECT id, kind, host, origin, url, title, alias, visits, own_opens, last_seen
              FROM entries
            """)
            while try select.step() {
                guard let kind = EntryKind(rawValue: select.text(1) ?? "") else { continue }
                entries.append(Entry(
                    id: select.int64(0),
                    kind: kind,
                    host: select.text(2) ?? "",
                    origin: select.text(3),
                    url: select.text(4),
                    title: select.text(5),
                    alias: select.text(6),
                    visits: select.int(7),
                    ownOpens: select.int(8),
                    lastSeen: select.int64(9)
                ))
            }

            var deepLinks: [DeepLink] = []
            let links = try db.prepare("SELECT host, url, title, visits FROM deep_links")
            while try links.step() {
                deepLinks.append(DeepLink(
                    host: links.text(0) ?? "",
                    url: links.text(1) ?? "",
                    title: links.text(2),
                    visits: links.int(3)
                ))
            }

            let topLinks = topDeepLinks(deepLinks, limitPerHost: 5)

            var apps: [StoredApp] = []
            let appStatement = try db.prepare(
                "SELECT id, bundle_id, name, path, own_opens FROM apps ORDER BY name COLLATE NOCASE"
            )
            while try appStatement.step() {
                apps.append(StoredApp(
                    id: appStatement.int64(0),
                    bundleID: appStatement.text(1),
                    name: appStatement.text(2) ?? "",
                    path: appStatement.text(3) ?? "",
                    ownOpens: appStatement.int(4)
                ))
            }

            var folders: [StoredFolder] = []
            let folderStatement = try db.prepare(
                "SELECT id, path, name, visits, own_opens, last_seen, sources FROM folders ORDER BY name COLLATE NOCASE"
            )
            while try folderStatement.step() {
                let path = folderStatement.text(1) ?? ""
                guard FolderHistoryScanner.canonicalDirectory(path) != nil else { continue }
                let sources = (folderStatement.text(6) ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                folders.append(StoredFolder(
                    id: folderStatement.int64(0),
                    path: path,
                    name: folderStatement.text(2) ?? "",
                    visits: folderStatement.int(3),
                    ownOpens: folderStatement.int(4),
                    lastSeen: folderStatement.int64(5),
                    sources: sources
                ))
            }

            return StoreSnapshot(entries: entries, deepLinks: topLinks, apps: apps, folders: folders)
        }
    }

    private func topDeepLinks(_ links: [DeepLink], limitPerHost: Int) -> [DeepLink] {
        var grouped: [String: [DeepLink]] = [:]
        for link in links {
            grouped[link.host, default: []].append(link)
        }
        var result: [DeepLink] = []
        for (_, group) in grouped {
            let sorted = group.sorted { lhs, rhs in
                if lhs.visits != rhs.visits { return lhs.visits > rhs.visits }
                return lhs.url < rhs.url
            }
            result.append(contentsOf: sorted.prefix(limitPerHost))
        }
        return result
    }

    // MARK: - Helpers

    func journalMode() throws -> String {
        try queue.sync {
            let statement = try db.prepare("PRAGMA journal_mode")
            _ = try statement.step()
            return statement.text(0) ?? ""
        }
    }

    func schemaVersion() throws -> Int32 {
        try queue.sync { try db.userVersion() }
    }

    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try db.exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try db.exec("COMMIT")
            return value
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }
}