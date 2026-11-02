import Foundation

public struct IndexEntry: Equatable {
    public let id: Int64
    public let kind: EntryKind
    public let isDeepLink: Bool
    public let host: String
    public let title: String?
    public let alias: String?
    public let url: String?
    public let openTarget: String
    public let visits: Int
    public let lastSeen: Int64
    public let haystack: String

    public var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        if let title, !title.isEmpty { return title }
        return host
    }
}

/// In-memory search over the archived entries. Reloaded after every sync.
public final class SearchIndex {
    private var entries: [IndexEntry] = []
    private var manualEntries: [IndexEntry] = []
    private var historyEntries: [IndexEntry] = []
    private var folderEntries: [IndexEntry] = []

    public init() {}

    public func update(entries sourceEntries: [Entry], deepLinks: [DeepLink],
                       apps: [StoredApp] = [], folders: [StoredFolder] = []) {
        var all: [IndexEntry] = []
        all.reserveCapacity(sourceEntries.count + deepLinks.count)

        for entry in sourceEntries {
            let haystack = Self.makeHaystack(
                host: entry.host,
                title: entry.title,
                alias: entry.alias,
                url: entry.kind == .history ? nil : entry.url
            )
            all.append(IndexEntry(
                id: entry.id,
                kind: entry.kind,
                isDeepLink: false,
                host: entry.host,
                title: entry.title,
                alias: entry.alias,
                url: entry.url,
                openTarget: entry.openTarget,
                visits: entry.visits,
                lastSeen: entry.lastSeen,
                haystack: haystack
            ))
        }

        for link in deepLinks {
            let haystack = Self.makeHaystack(host: link.host, title: link.title, alias: nil, url: link.url)
            all.append(IndexEntry(
                id: 0,
                kind: .history,
                isDeepLink: true,
                host: link.host,
                title: link.title,
                alias: nil,
                url: link.url,
                openTarget: link.url,
                visits: link.visits,
                lastSeen: 0,
                haystack: haystack
            ))
        }

        for app in apps {
            var parts = [app.name.lowercased()]
            if let bundleID = app.bundleID, !bundleID.isEmpty {
                parts.append(bundleID.lowercased())
            }
            all.append(IndexEntry(
                id: app.id,
                kind: .app,
                isDeepLink: false,
                host: app.name.lowercased(),
                title: app.name,
                alias: nil,
                url: app.path,
                openTarget: app.path,
                visits: app.ownOpens,
                lastSeen: 0,
                haystack: parts.joined(separator: " ")
            ))
        }

        for folder in folders {
            let haystack = "\(folder.name.lowercased()) \(folder.path.lowercased())"
            all.append(IndexEntry(
                id: folder.id,
                kind: .folder,
                isDeepLink: false,
                host: folder.name.lowercased(),
                title: folder.name,
                alias: nil,
                url: folder.path,
                openTarget: folder.path,
                visits: folder.visits + folder.ownOpens,
                lastSeen: folder.lastSeen,
                haystack: haystack
            ))
        }

        entries = all
        manualEntries = all.filter { $0.kind == .manual }
        historyEntries = all.filter { $0.kind == .history && !$0.isDeepLink }
        folderEntries = all.filter { $0.kind == .folder }
    }

    /// The empty-query list: manual entries first, then history by visit count.
    public func defaultEntries() -> [IndexEntry] {
        let manual = manualEntries.sorted { lhs, rhs in
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.openTarget < rhs.openTarget
        }
        return manual + sortedByPopularity(historyEntries)
    }

    public func search(_ query: String) -> [IndexEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // `~` switches to a folder-only view; `~` alone lists recent folders.
        if trimmed.hasPrefix("~") {
            let remainder = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !remainder.isEmpty else { return sortedByPopularity(folderEntries) }
            let tokens = remainder.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let matched = folderEntries.filter { entry in
                tokens.allSatisfy { entry.haystack.contains($0) }
            }
            return sorted(matched, query: remainder, tokens: tokens)
        }

        let lowered = trimmed.lowercased()
        guard !lowered.isEmpty else { return defaultEntries() }
        let tokens = lowered.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return defaultEntries() }

        let matched = entries.filter { entry in
            tokens.allSatisfy { entry.haystack.contains($0) }
        }
        return sorted(matched, query: lowered, tokens: tokens)
    }

    private func sorted(_ source: [IndexEntry], query: String, tokens: [String]) -> [IndexEntry] {
        source.sorted { lhs, rhs in
            let leftTier = tier(for: lhs, query: query, tokens: tokens)
            let rightTier = tier(for: rhs, query: query, tokens: tokens)
            if leftTier != rightTier { return leftTier < rightTier }
            if lhs.visits != rhs.visits { return lhs.visits > rhs.visits }
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.openTarget < rhs.openTarget
        }
    }

    private func tier(for entry: IndexEntry, query: String, tokens: [String]) -> Int {
        if entry.host == query { return 0 }
        if entry.host.hasPrefix(query) { return 1 }
        if tokens.allSatisfy({ entry.host.contains($0) }) { return 2 }
        return 3
    }

    private func sortedByPopularity(_ source: [IndexEntry]) -> [IndexEntry] {
        source.sorted { lhs, rhs in
            if lhs.visits != rhs.visits { return lhs.visits > rhs.visits }
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.openTarget < rhs.openTarget
        }
    }

    private static func makeHaystack(host: String, title: String?, alias: String?, url: String?) -> String {
        var parts = [host.lowercased()]
        if let title, !title.isEmpty { parts.append(title.lowercased()) }
        if let alias, !alias.isEmpty { parts.append(alias.lowercased()) }
        if let url {
            let path = URLTools.searchablePath(of: url)
            if !path.isEmpty { parts.append(path.lowercased()) }
        }
        return parts.joined(separator: " ")
    }
}