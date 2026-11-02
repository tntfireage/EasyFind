import Foundation

public struct FileScanResult {
    public let files: [FileCandidate]
    public let directories: [FolderCandidate]

    public init(files: [FileCandidate], directories: [FolderCandidate]) {
        self.files = files
        self.directories = directories
    }

    public static let empty = FileScanResult(files: [], directories: [])
}

/// Walks a configured set of directories and produces file and directory
/// candidates for the in-memory search index. The scan runs on the caller's
/// queue; `SyncCoordinator` invokes it on its background sync queue so the UI
/// stays responsive.
public enum FileScanner {
    /// Roots that never belong in the index even when explicitly configured.
    /// `/usr/local` and `/opt/homebrew` are exempt (user-installed tooling).
    public static let deniedSystemPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db",
        "/private/var/root", "/dev", "/Library", "/Applications", "/cores", "/Network"
    ]
    private static let allowedSystemPrefixes = ["/usr/local", "/opt/homebrew"]

    /// Directory names skipped during the walk. These are build output, dependency
    /// trees, and caches that would drown out the user's real files. `Library` is
    /// handled separately so a user folder such as `Documents/Library` is kept.
    public static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "Pods", "DerivedData",
        "__pycache__", ".venv", "venv", "Caches"
    ]

    /// Hidden entries that are noise even when `includeHidden` is enabled.
    private static let ignoredHiddenNames: Set<String> = [
        ".DS_Store", ".localized", ".VolumeIcon.icns",
        ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", ".MobileBackups", ".com.apple.timemachine.donotpresent"
    ]

    /// Package directories that may still contain user-readable source files.
    /// Everything else that macOS marks as a package (`.app`, `.framework`, …)
    /// is skipped entirely.
    private static let traversablePackageExtensions: Set<String> = ["plugin"]

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .contentModificationDateKey
    ]

    public static func scan(directories: [String], maxFiles: Int = 20_000) -> [FileCandidate] {
        scanAll(directories: directories, maxFiles: maxFiles).files
    }

    public static func scanAll(directories: [String], maxFiles: Int = 20_000,
                               maxDirectories: Int = 5_000,
                               includeHidden: Bool = false) -> FileScanResult {
        guard maxFiles > 0 || maxDirectories > 0 else { return .empty }

        var files: [FileCandidate] = []
        var directoriesFound: [FolderCandidate] = []
        var seenFiles = Set<String>()
        var seenDirectories = Set<String>()

        let options: FileManager.DirectoryEnumerationOptions = includeHidden
            ? [] : [.skipsHiddenFiles]

        func addDirectory(_ url: URL, values: URLResourceValues) {
            guard directoriesFound.count < maxDirectories else { return }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
            let key = canonical.lowercased()
            guard seenDirectories.insert(key).inserted else { return }
            let modified = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            directoriesFound.append(FolderCandidate(
                key: key,
                path: canonical,
                name: url.lastPathComponent,
                visits: 0,
                lastSeen: modified,
                sources: ["scan"]
            ))
        }

        outer: for raw in directories {
            guard let root = FolderHistoryScanner.canonicalDirectory(raw) else { continue }
            guard !isDeniedSystemPath(root) else {
                NSLog("EasyFind: skipping system directory for file index: %@", root)
                continue
            }

            let rootURL = URL(fileURLWithPath: root)
            if let values = try? rootURL.resourceValues(forKeys: resourceKeys),
               values.isDirectory == true, values.isPackage != true {
                addDirectory(rootURL, values: values)
            }

            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: options,
                errorHandler: { url, error in
                    NSLog("EasyFind: file scan skipped %@: %@", url.path, String(describing: error))
                    return true
                }
            )

            while let url = enumerator?.nextObject() as? URL {
                if maxFiles > 0 && files.count >= maxFiles { break outer }

                guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
                let name = url.lastPathComponent

                if values.isDirectory == true {
                    if shouldSkipDirectory(url, values: values, includeHidden: includeHidden) {
                        enumerator?.skipDescendants()
                        continue
                    }
                    if values.isPackage != true {
                        addDirectory(url, values: values)
                    }
                    continue
                }

                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      !isDeniedSystemPath(url.path) else { continue }
                if includeHidden && ignoredHiddenNames.contains(name) { continue }

                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                let key = canonical.lowercased()
                guard seenFiles.insert(key).inserted else { continue }

                let modified = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
                files.append(FileCandidate(
                    key: key,
                    path: canonical,
                    name: name,
                    visits: 0,
                    lastSeen: modified,
                    sources: ["scan"]
                ))
            }
        }

        if maxFiles > 0 && files.count >= maxFiles {
            NSLog("EasyFind: file index reached the %d file cap", maxFiles)
        }
        if directoriesFound.count >= maxDirectories {
            NSLog("EasyFind: directory index reached the %d directory cap", maxDirectories)
        }
        return FileScanResult(files: files, directories: directoriesFound)
    }

    private static func shouldSkipDirectory(_ url: URL, values: URLResourceValues,
                                            includeHidden: Bool) -> Bool {
        let name = url.lastPathComponent
        if skippedDirectoryNames.contains(name) { return true }
        if includeHidden && ignoredHiddenNames.contains(name) { return true }
        if !includeHidden && name.hasPrefix(".") { return true }
        if name == "Library" {
            return url.deletingLastPathComponent().standardizedFileURL.path == NSHomeDirectory()
        }
        if values.isPackage == true {
            return !traversablePackageExtensions.contains(url.pathExtension.lowercased())
        }
        return false
    }

    /// Resolves symlinks, standardizes, and requires an existing regular file.
    public static func canonicalFile(_ raw: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    public static func isDeniedSystemPath(_ path: String) -> Bool {
        for allowed in allowedSystemPrefixes where path == allowed || path.hasPrefix(allowed + "/") {
            return false
        }
        for denied in deniedSystemPrefixes where path == denied || path.hasPrefix(denied + "/") {
            return true
        }
        return false
    }

    public static func contains(_ path: String, roots: [String]) -> Bool {
        roots.contains { root in path == root || path.hasPrefix(root + "/") }
    }
}

/// Merges the directory scan with the system recent-documents list.
public enum FileCatalog {
    public static func merge(scanned: [FileCandidate], recent: [FileCandidate],
                             directories: [String]) -> [FileCandidate] {
        let roots = directories.compactMap { FolderHistoryScanner.canonicalDirectory($0) }

        struct Merged {
            var path: String
            var name: String
            var visits: Int
            var lastSeen: Int64
            var sources: Set<String>
        }

        var byKey: [String: Merged] = [:]

        func add(path: String, name: String, visits: Int, lastSeen: Int64, source: String) {
            let key = path.lowercased()
            var merged = byKey[key] ?? Merged(
                path: path, name: name, visits: 0, lastSeen: 0, sources: []
            )
            merged.visits = max(merged.visits, visits)
            merged.lastSeen = max(merged.lastSeen, lastSeen)
            merged.sources.insert(source)
            byKey[key] = merged
        }

        for file in scanned {
            add(path: file.path, name: file.name, visits: file.visits,
                lastSeen: file.lastSeen, source: "scan")
            if !file.sources.isEmpty {
                for source in file.sources where source != "scan" {
                    add(path: file.path, name: file.name, visits: file.visits,
                        lastSeen: file.lastSeen, source: source)
                }
            }
        }

        for file in recent {
            guard let canonical = FileScanner.canonicalFile(file.path) else { continue }
            guard !roots.isEmpty, FileScanner.contains(canonical, roots: roots) else { continue }
            guard !FileScanner.isDeniedSystemPath(canonical) else { continue }
            add(path: canonical, name: URL(fileURLWithPath: canonical).lastPathComponent,
                visits: file.visits, lastSeen: file.lastSeen, source: "recent")
        }

        return byKey.values.map { merged in
            FileCandidate(
                key: merged.path.lowercased(),
                path: merged.path,
                name: merged.name,
                visits: merged.visits,
                lastSeen: merged.lastSeen,
                sources: merged.sources.sorted()
            )
        }.sorted { $0.path < $1.path }
    }
}
