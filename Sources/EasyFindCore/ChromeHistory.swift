import Foundation

public struct ChromeProfile: Equatable {
    public let name: String
    public let historyURL: URL
    public let walURL: URL
    public let shmURL: URL

    public init(name: String, historyURL: URL, walURL: URL, shmURL: URL) {
        self.name = name
        self.historyURL = historyURL
        self.walURL = walURL
        self.shmURL = shmURL
    }
}

public enum ChromeProfileDiscovery {
    public static func profiles(root: URL) -> [ChromeProfile] {
        let fileManager = FileManager.default
        var profiles: [ChromeProfile] = []

        // Some Chromium-family roots (e.g. Opera) keep History directly under the root.
        let rootHistory = root.appendingPathComponent("History")
        if fileManager.fileExists(atPath: rootHistory.path) {
            profiles.append(ChromeProfile(
                name: root.lastPathComponent,
                historyURL: rootHistory,
                walURL: root.appendingPathComponent("History-wal"),
                shmURL: root.appendingPathComponent("History-shm")
            ))
        }

        if let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let history = child.appendingPathComponent("History")
                guard fileManager.fileExists(atPath: history.path) else { continue }
                profiles.append(ChromeProfile(
                    name: child.lastPathComponent,
                    historyURL: history,
                    walURL: child.appendingPathComponent("History-wal"),
                    shmURL: child.appendingPathComponent("History-shm")
                ))
            }
        }

        return profiles.sorted { $0.name < $1.name }
    }
}

public struct FileStamp: Equatable {
    public let modificationTime: TimeInterval
    public let size: Int64

    public init(modificationTime: TimeInterval, size: Int64) {
        self.modificationTime = modificationTime
        self.size = size
    }
}

/// Copies Chrome's live `History` (+ WAL/SHM) out of the way before reading it,
/// and remembers a signature so unchanged profiles are skipped.
public final class ChromeHistorySnapshotter {
    public let tempRoot: URL
    private var signatures: [String: ProfileSignature] = [:]

    struct ProfileSignature: Equatable {
        let history: FileStamp?
        let wal: FileStamp?
        let shm: FileStamp?
    }

    public init(tempRoot: URL) {
        self.tempRoot = tempRoot
    }

    public func refreshNeeded(for profile: ChromeProfile) -> Bool {
        let current = signature(for: profile)
        guard let known = signatures[profile.name] else { return true }
        return known != current
    }

    @discardableResult
    public func makeSnapshot(for profile: ChromeProfile) throws -> URL {
        let fileManager = FileManager.default
        let directory = tempRoot.appendingPathComponent(profile.name, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent("History")
        try fileManager.copyItem(at: profile.historyURL, to: destination)

        if fileManager.fileExists(atPath: profile.walURL.path) {
            try fileManager.copyItem(at: profile.walURL, to: directory.appendingPathComponent("History-wal"))
        }
        if fileManager.fileExists(atPath: profile.shmURL.path) {
            try fileManager.copyItem(at: profile.shmURL, to: directory.appendingPathComponent("History-shm"))
        }

        signatures[profile.name] = signature(for: profile)
        return destination
    }

    /// Removes one profile's copied files after it has been read.
    public func removeSnapshot(at historyPath: URL) {
        let directory = historyPath.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Forces the next sync to re-read a profile (used after a parse failure).
    public func invalidate(_ profile: ChromeProfile) {
        signatures.removeValue(forKey: profile.name)
    }

    public func removeAllSnapshots() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func signature(for profile: ChromeProfile) -> ProfileSignature {
        ProfileSignature(
            history: stamp(for: profile.historyURL),
            wal: stamp(for: profile.walURL),
            shm: stamp(for: profile.shmURL)
        )
    }

    private func stamp(for url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return FileStamp(modificationTime: modified, size: size)
    }
}

public struct ChromeHistoryRow: Equatable {
    public let url: String
    public let title: String?
    public let visitCount: Int
    public let lastVisitTime: Int64

    public init(url: String, title: String?, visitCount: Int, lastVisitTime: Int64) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitTime = lastVisitTime
    }
}

public enum ChromeHistoryReader {
    public static func readRows(at path: String) throws -> [ChromeHistoryRow] {
        // The file is a disposable snapshot, so a normal (writable) open is used:
        // read-only opens of a WAL database can fail when the -shm file is absent.
        let database = try SQLiteDatabase(path: path)
        let statement = try database.prepare(
            "SELECT url, title, visit_count, last_visit_time FROM urls"
        )
        var rows: [ChromeHistoryRow] = []
        while try statement.step() {
            guard let url = statement.text(0), !url.isEmpty else { continue }
            rows.append(ChromeHistoryRow(
                url: url,
                title: statement.text(1),
                visitCount: statement.int(2),
                lastVisitTime: ChromiumTime.unixSeconds(fromChromiumMicroseconds: statement.int64(3))
            ))
        }
        return rows
    }
}

public enum ChromiumTime {
    /// Seconds between 1601-01-01 (Chromium's epoch) and 1970-01-01.
    public static let epochOffsetSeconds: Int64 = 11_644_473_600

    public static func unixSeconds(fromChromiumMicroseconds microseconds: Int64) -> Int64 {
        microseconds / 1_000_000 - epochOffsetSeconds
    }
}