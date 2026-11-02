import Foundation

/// Reads the system's recently used documents through Spotlight metadata
/// (`kMDItemLastUsedDate`) and scopes them to the configured directories.
public enum RecentFilesScanner {
    public struct Item: Equatable {
        public let path: String
        public let lastUsed: Date

        public init(path: String, lastUsed: Date) {
            self.path = path
            self.lastUsed = lastUsed
        }
    }

    public typealias Provider = (_ directories: [String], _ since: Date, _ limit: Int) -> [Item]

    public static func scan(directories: [String], limit: Int = 300, now: Date = Date(),
                            lookbackDays: Int = 365, provider: Provider? = nil) -> [FileCandidate] {
        guard limit > 0 else { return [] }
        let expanded = directories.map { ($0 as NSString).expandingTildeInPath }
        let roots = expanded.compactMap { FolderHistoryScanner.canonicalDirectory($0) }
        guard !roots.isEmpty else { return [] }

        let since = now.addingTimeInterval(-Double(max(lookbackDays, 1)) * 86_400)
        let items = (provider ?? metadataProvider)(expanded, since, limit)

        var result: [FileCandidate] = []
        var seen = Set<String>()
        for item in items.prefix(limit) {
            guard let canonical = FileScanner.canonicalFile(item.path) else { continue }
            guard FileScanner.contains(canonical, roots: roots) else { continue }
            guard !FileScanner.isDeniedSystemPath(canonical) else { continue }
            let key = canonical.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(FileCandidate(
                key: key,
                path: canonical,
                name: URL(fileURLWithPath: canonical).lastPathComponent,
                visits: 0,
                lastSeen: Int64(item.lastUsed.timeIntervalSince1970),
                sources: ["recent"]
            ))
        }
        return result
    }

    /// Synchronous wrapper around `NSMetadataQuery`; safe to call from the sync
    /// queue. Spotlight runs its query on the main run loop, so this waits with a
    /// bounded timeout and never blocks the UI thread.
    static func metadataProvider(directories: [String], since: Date, limit: Int) -> [Item] {
        let scopes = directories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !scopes.isEmpty else { return [] }

        let query = NSMetadataQuery()
        query.searchScopes = scopes
        query.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@", since as NSDate)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]

        let lock = NSLock()
        var items: [Item] = []
        var finished = false

        func collect() {
            query.disableUpdates()
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let count = min(query.resultCount, limit)
            for index in 0..<count {
                guard let result = query.result(at: index) as? NSMetadataItem,
                      let path = result.value(forAttribute: NSMetadataItemPathKey) as? String,
                      let date = result.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date else {
                    continue
                }
                items.append(Item(path: path, lastUsed: date))
            }
            lock.unlock()
        }

        func isFinished() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: nil
        ) { _ in
            collect()
        }

        if Thread.isMainThread {
            query.start()
            let deadline = Date().addingTimeInterval(10)
            while !isFinished() && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        } else {
            DispatchQueue.main.async { query.start() }
            let deadline = Date().addingTimeInterval(10)
            while !isFinished() && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        lock.lock()
        finished = true
        let snapshot = items
        lock.unlock()

        NotificationCenter.default.removeObserver(observer)
        if Thread.isMainThread {
            query.stop()
        } else {
            DispatchQueue.main.async { query.stop() }
        }
        return snapshot
    }
}
