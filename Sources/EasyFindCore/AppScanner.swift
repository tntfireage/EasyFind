import Foundation

/// Enumerates installed `.app` bundles in the standard macOS application roots.
public enum AppScanner {
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    /// Roots are visited in priority order; the first copy of a bundle identifier wins.
    public static func scan(roots: [URL] = defaultRoots) -> [InstalledApp] {
        var seenBundleIDs = Set<String>()
        var seenPaths = Set<String>()
        var result: [InstalledApp] = []

        for root in roots {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children where child.pathExtension.lowercased() == "app" {
                guard let app = readApp(at: child) else { continue }
                if let bundleID = app.bundleID {
                    guard seenBundleIDs.insert(bundleID).inserted else { continue }
                } else {
                    guard seenPaths.insert(app.path).inserted else { continue }
                }
                result.append(app)
            }
        }

        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func readApp(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url),
              let executable = bundle.executableURL,
              FileManager.default.fileExists(atPath: executable.path) else { return nil }

        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        let displayName = (info["CFBundleDisplayName"] as? String)?.trimmed
        let bundleName = (info["CFBundleName"] as? String)?.trimmed
        let filename = url.deletingPathExtension().lastPathComponent
        let name = [displayName, bundleName, filename]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? filename

        let bundleID = bundle.bundleIdentifier?.trimmed
        return InstalledApp(
            bundleID: (bundleID?.isEmpty == false) ? bundleID : nil,
            name: name,
            path: url.resolvingSymlinksInPath().path
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}