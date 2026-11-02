import Foundation

private struct HistoryRowInfo {
    let url: String
    let title: String?
    let visits: Int
    let lastSeen: Int64
}

public enum HistoryAggregator {
    public static func aggregate(_ rows: [ChromeHistoryRow]) -> [HostAggregate] {
        struct Bucket {
            var visits = 0
            var lastSeen: Int64 = 0
            var rows: [HistoryRowInfo] = []
        }

        var buckets: [String: Bucket] = [:]
        for row in rows {
            guard let host = URLTools.host(of: row.url) else { continue }
            guard let scheme = URLComponents(string: row.url)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            var bucket = buckets[host] ?? Bucket()
            bucket.visits += row.visitCount
            bucket.lastSeen = max(bucket.lastSeen, row.lastVisitTime)
            bucket.rows.append(HistoryRowInfo(url: row.url, title: row.title, visits: row.visitCount, lastSeen: row.lastVisitTime))
            buckets[host] = bucket
        }

        let aggregates: [HostAggregate] = buckets.map { host, bucket in
            let best = bucket.rows.max { lhs, rhs in
                if lhs.visits != rhs.visits { return lhs.visits < rhs.visits }
                return lhs.lastSeen < rhs.lastSeen
            }
            let origin = best.flatMap { URLTools.origin(of: $0.url) } ?? "https://\(host)"
            let bestTitle = best?.title.flatMap { $0.isEmpty ? nil : $0 }
            let fallbackTitle = bucket.rows.compactMap(\.title).first { !$0.isEmpty }
            return HostAggregate(
                host: host,
                origin: origin,
                title: bestTitle ?? fallbackTitle,
                visits: bucket.visits,
                lastSeen: bucket.lastSeen,
                deepLinks: topDeepLinks(bucket.rows, limit: 5)
            )
        }

        return aggregates.sorted { $0.host < $1.host }
    }

    private static func topDeepLinks(_ rows: [HistoryRowInfo], limit: Int) -> [DeepLinkAggregate] {
        var seen = Set<String>()
        let sorted = rows.sorted { lhs, rhs in
            if lhs.visits != rhs.visits { return lhs.visits > rhs.visits }
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.url < rhs.url
        }
        var result: [DeepLinkAggregate] = []
        for row in sorted {
            guard seen.insert(row.url).inserted else { continue }
            result.append(DeepLinkAggregate(url: row.url, title: row.title, visits: row.visits))
            if result.count == limit { break }
        }
        return result
    }
}

public enum HistoryMerger {
    public static func merge(_ lists: [[HostAggregate]]) -> [HostAggregate] {
        var grouped: [String: [HostAggregate]] = [:]
        for list in lists {
            for aggregate in list {
                grouped[aggregate.host, default: []].append(aggregate)
            }
        }

        let merged: [HostAggregate] = grouped.map { host, group in
            let visits = group.reduce(0) { $0 + $1.visits }
            let lastSeen = group.map(\.lastSeen).max() ?? 0
            let best = group.max { lhs, rhs in
                if lhs.visits != rhs.visits { return lhs.visits < rhs.visits }
                return lhs.lastSeen < rhs.lastSeen
            }
            let bestTitle = best?.title.flatMap { $0.isEmpty ? nil : $0 }
            let fallbackTitle = group.compactMap(\.title).first { !$0.isEmpty }
            return HostAggregate(
                host: host,
                origin: best?.origin ?? "https://\(host)",
                title: bestTitle ?? fallbackTitle,
                visits: visits,
                lastSeen: lastSeen,
                deepLinks: mergeDeepLinks(group.flatMap(\.deepLinks))
            )
        }

        return merged.sorted { $0.host < $1.host }
    }

    private static func mergeDeepLinks(_ links: [DeepLinkAggregate]) -> [DeepLinkAggregate] {
        var byURL: [String: DeepLinkAggregate] = [:]
        for link in links {
            if let existing = byURL[link.url] {
                byURL[link.url] = DeepLinkAggregate(
                    url: link.url,
                    title: existing.title ?? link.title,
                    visits: existing.visits + link.visits
                )
            } else {
                byURL[link.url] = link
            }
        }
        let sorted = byURL.values.sorted { lhs, rhs in
            if lhs.visits != rhs.visits { return lhs.visits > rhs.visits }
            return lhs.url < rhs.url
        }
        return Array(sorted.prefix(5))
    }
}

public final class ChromeHistoryCollector {
    public let root: URL
    private let snapshotter: ChromeHistorySnapshotter
    private var cache: [String: [HostAggregate]] = [:]
    private let lock = NSLock()

    public init(root: URL, snapshotter: ChromeHistorySnapshotter? = nil) {
        self.root = root
        if let snapshotter {
            self.snapshotter = snapshotter
        } else {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("easyfind-history-\(UUID().uuidString)", isDirectory: true)
            self.snapshotter = ChromeHistorySnapshotter(tempRoot: tempRoot)
        }
    }

    public func collect() throws -> [HostAggregate] {
        lock.lock()
        defer { lock.unlock() }

        let profiles = ChromeProfileDiscovery.profiles(root: root)
        var lists: [[HostAggregate]] = []

        for profile in profiles {
            if !snapshotter.refreshNeeded(for: profile), let cached = cache[profile.name] {
                lists.append(cached)
                continue
            }

            do {
                let snapshot = try snapshotter.makeSnapshot(for: profile)
                defer { snapshotter.removeSnapshot(at: snapshot) }
                let rows = try ChromeHistoryReader.readRows(at: snapshot.path)
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

        // The copies are no longer needed; signatures are kept so unchanged
        // profiles are still skipped on the next sync.
        snapshotter.removeAllSnapshots()

        return HistoryMerger.merge(lists)
    }

    public func resetCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}