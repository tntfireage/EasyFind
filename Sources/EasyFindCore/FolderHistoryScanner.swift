import Foundation

/// Collects directory history from editor recents, Finder, and zsh `cd` commands.
/// Everything is normalized to a canonical full path and deduplicated by lowercased path.
public enum FolderHistoryScanner {
    public struct Candidate: Equatable {
        public let path: String
        public let visits: Int
        public let lastSeen: Int64
    }

    public static var defaultZshHistoryURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls = [home.appendingPathComponent(".zsh_history")]
        let sessions = home.appendingPathComponent(".zsh_sessions", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: sessions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: files
                .filter { $0.pathExtension == "history" }
                .sorted { $0.path < $1.path })
        }
        return urls
    }

    public static var defaultEditorStateURLs: [URL] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ["Code", "Cursor"].map {
            base.appendingPathComponent("\($0)/User/globalStorage/state.vscdb")
        }
    }

    public static func scan(
        zshHistoryURLs: [URL] = defaultZshHistoryURLs,
        editorStateURLs: [URL] = defaultEditorStateURLs,
        includeFinder: Bool = true
    ) -> [FolderCandidate] {
        let now = Int64(Date().timeIntervalSince1970)
        var merged: [String: (path: String, name: String, visits: Int, lastSeen: Int64, sources: Set<String>)] = [:]

        func add(rawPath: String, visits: Int, lastSeen: Int64, source: String) {
            guard let canonical = canonicalDirectory(rawPath) else { return }
            let key = canonical.lowercased()
            var entry = merged[key] ?? (
                path: canonical,
                name: URL(fileURLWithPath: canonical).lastPathComponent,
                visits: 0,
                lastSeen: 0,
                sources: []
            )
            entry.visits = max(entry.visits, visits)
            entry.lastSeen = max(entry.lastSeen, lastSeen)
            entry.sources.insert(source)
            merged[key] = entry
        }

        for url in zshHistoryURLs {
            for item in parseZshHistory(at: url, now: now) {
                add(rawPath: item.path, visits: item.visits, lastSeen: item.lastSeen, source: "shell")
            }
        }

        for url in editorStateURLs {
            let source = url.path.contains("/Cursor/") ? "cursor" : "code"
            for item in parseEditorState(at: url, now: now) {
                add(rawPath: item.path, visits: 1, lastSeen: item.lastSeen, source: source)
            }
        }

        if includeFinder {
            for item in finderRecentFolders(now: now) {
                add(rawPath: item.path, visits: 1, lastSeen: item.lastSeen, source: "finder")
            }
        }

        return merged.values.map {
            FolderCandidate(
                key: $0.path.lowercased(),
                path: $0.path,
                name: $0.name,
                visits: $0.visits,
                lastSeen: $0.lastSeen,
                sources: $0.sources.sorted()
            )
        }.sorted { $0.path < $1.path }
    }

    // MARK: - Canonicalization

    /// Resolves symlinks, standardizes, and requires an existing directory that is
    /// not a package (`.app`, saved searches, and similar bundles are excluded).
    public static func canonicalDirectory(_ raw: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        let url = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory == true,
              values.isPackage != true else { return nil }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    // MARK: - zsh

    static func parseZshHistory(at url: URL, now: Int64) -> [Candidate] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970
        let lastSeen = Int64(modified ?? Double(now))

        var counts: [String: Int] = [:]
        for rawLine in data.split(separator: 0x0A) {
            // Lossy decoding: history files can contain invalid UTF-8.
            let line = String(decoding: rawLine, as: UTF8.self)
            guard let argument = cdArgument(line) else { continue }
            guard argument.hasPrefix("/") || argument.hasPrefix("~") else { continue }
            guard let canonical = canonicalDirectory(argument) else { continue }
            counts[canonical, default: 0] += 1
        }

        return counts.map { Candidate(path: $0.key, visits: $0.value, lastSeen: lastSeen) }
    }

    static func cdArgument(_ rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }

        // zsh extended history: ": <timestamp>:<elapsed>;<command>"
        if line.hasPrefix(":"), let separator = line.firstIndex(of: ";") {
            line = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard line.hasPrefix("cd ") || line.hasPrefix("cd\t") else { return nil }
        var argument = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !argument.isEmpty else { return nil }

        for separator in ["&&", "||", ";", "|"] {
            if let range = argument.range(of: separator) {
                argument = String(argument[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        if argument.count >= 2,
           let first = argument.first,
           let last = argument.last,
           first == last,
           first == "\"" || first == "'" {
            argument = String(argument.dropFirst().dropLast())
        }

        return argument
    }

    // MARK: - Editors

    static func parseEditorState(at url: URL, now: Int64) -> [Candidate] {
        guard FileManager.default.fileExists(atPath: url.path),
              let database = try? SQLiteDatabase(path: url.path, readOnly: true) else {
            return []
        }
        _ = try? database.exec("PRAGMA busy_timeout=2000")
        guard let statement = try? database.prepare(
                  "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'"
              ),
              (try? statement.step()) == true,
              let json = statement.text(0),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            return []
        }

        var result: [Candidate] = []
        for (index, entry) in entries.enumerated() {
            let lastSeen = now - Int64(index)
            if let uri = entry["folderUri"] as? String, let path = filePath(from: uri) {
                result.append(Candidate(path: path, visits: 1, lastSeen: lastSeen))
            } else if let uri = entry["fileUri"] as? String, let path = filePath(from: uri) {
                result.append(Candidate(
                    path: (path as NSString).deletingLastPathComponent,
                    visits: 1,
                    lastSeen: lastSeen
                ))
            }
        }
        return result
    }

    private static func filePath(from uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    // MARK: - Finder

    static func finderRecentFolders(now: Int64) -> [Candidate] {
        let application = "com.apple.finder" as CFString
        CFPreferencesAppSynchronize(application)
        guard let items = CFPreferencesCopyAppValue("FXRecentFolders" as CFString, application) as? [Any] else {
            return []
        }
        return parseFinderItems(items, now: now)
    }

    /// Extracted for testability: Finder stores an array of `{ name, file-bookmark }` dictionaries.
    static func parseFinderItems(_ items: [Any], now: Int64) -> [Candidate] {
        var result: [Candidate] = []
        for (index, item) in items.enumerated() {
            guard let dictionary = item as? [String: Any] else { continue }
            let bookmark: Data?
            if let data = dictionary["file-bookmark"] as? Data {
                bookmark = data
            } else if let data = dictionary["file-bookmark"] as? NSData {
                bookmark = Data(referencing: data)
            } else {
                bookmark = nil
            }
            guard let bookmark else { continue }

            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), let canonical = canonicalDirectory(url.path) else { continue }

            result.append(Candidate(path: canonical, visits: 1, lastSeen: now - Int64(index)))
        }
        return result
    }
}