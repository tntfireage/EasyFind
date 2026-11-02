import Foundation

/// On-demand filename search through Spotlight. This complements the indexed
/// directories: the index covers configured roots and recent usage, while this
/// finds any user-visible file or directory outside those roots.
public enum LiveFileSearch {
    public enum Mode {
        case any
        case files
        case folders
    }

    /// Returns NUL-separated raw paths for the seed token.
    public typealias Runner = (_ seed: String, _ limit: Int) -> [String]

    public static let defaultAllowedRoots = [
        "/Users", "/Volumes", "/opt/homebrew", "/usr/local"
    ]

    public static func search(query: String, mode: Mode = .any,
                              includeHidden: Bool = false, limit: Int = 40,
                              allowedRoots: [String] = defaultAllowedRoots,
                              runner: Runner? = nil) -> [IndexEntry] {
        let tokens = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return [] }

        // Use the longest token as the Spotlight seed; the full token set is
        // re-checked against the path below.
        let seed = tokens.max(by: { $0.count < $1.count }) ?? tokens[0]
        guard seed.count >= 2 else { return [] }

        let rawPaths = (runner ?? mdfind)(seed, max(limit * 10, 100))
        let roots = allowedRoots.map { normalized($0) }

        var entries: [IndexEntry] = []
        var seen = Set<String>()
        let queryLower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for raw in rawPaths {
            guard let url = validatedURL(raw, mode: mode, includeHidden: includeHidden,
                                         roots: roots),
                  let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey,
                              .contentModificationDateKey]) else { continue }
            let path = url.path
            let name = url.lastPathComponent
            let haystack = "\(name.lowercased()) \(path.lowercased())"
            guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }
            guard seen.insert(path).inserted else { continue }

            let kind: EntryKind
            if values.isDirectory == true {
                guard values.isPackage != true, mode != .files else { continue }
                kind = .folder
            } else {
                guard values.isRegularFile == true, mode != .folders else { continue }
                kind = .file
            }

            let modified = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            entries.append(IndexEntry(
                id: 0,
                kind: kind,
                isDeepLink: false,
                host: name.lowercased(),
                title: name,
                alias: nil,
                url: path,
                openTarget: path,
                visits: 0,
                lastSeen: modified,
                haystack: haystack
            ))
            if entries.count >= limit { break }
        }

        return entries.sorted { lhs, rhs in
            let leftTier = tier(name: lhs.title ?? lhs.host, query: queryLower)
            let rightTier = tier(name: rhs.title ?? rhs.host, query: queryLower)
            if leftTier != rightTier { return leftTier < rightTier }
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.openTarget < rhs.openTarget
        }
    }

    private static func tier(name: String, query: String) -> Int {
        let lowered = name.lowercased()
        if lowered == query { return 0 }
        if lowered.hasPrefix(query) { return 1 }
        if lowered.contains(query) { return 2 }
        return 3
    }

    private static func validatedURL(_ raw: String, mode: Mode, includeHidden: Bool,
                                     roots: [String]) -> URL? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let path = url.path
        guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
        guard !FileScanner.isDeniedSystemPath(path) else { return nil }
        guard !isHidden(path, includeHidden: includeHidden) else { return nil }
        guard !hasSkippedComponent(path) else { return nil }
        return url
    }

    private static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func isHidden(_ path: String, includeHidden: Bool) -> Bool {
        guard !includeHidden else { return false }
        return path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    private static func hasSkippedComponent(_ path: String) -> Bool {
        let homeLibrary = NSHomeDirectory() + "/Library"
        if path == homeLibrary || path.hasPrefix(homeLibrary + "/") { return true }
        return path.split(separator: "/").contains {
            FileScanner.skippedDirectoryNames.contains(String($0))
        }
    }

    private static func mdfind(seed: String, limit: Int) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", "-name", seed]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("EasyFind: mdfind failed to start: %@", String(describing: error))
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\0")
            .map(String.init)
    }
}
