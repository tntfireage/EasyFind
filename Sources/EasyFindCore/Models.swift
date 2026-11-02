import Foundation

public enum EntryKind: String, Codable, CaseIterable {
    case history
    case bookmark
    case manual
    case app
    case folder
    case file
}

public struct Entry: Equatable {
    public let id: Int64
    public let kind: EntryKind
    public let host: String
    public let origin: String?
    public let url: String?
    public let title: String?
    public let alias: String?
    public let visits: Int
    public let ownOpens: Int
    public let lastSeen: Int64

    public init(id: Int64, kind: EntryKind, host: String, origin: String?, url: String?,
                title: String?, alias: String?, visits: Int, ownOpens: Int, lastSeen: Int64) {
        self.id = id
        self.kind = kind
        self.host = host
        self.origin = origin
        self.url = url
        self.title = title
        self.alias = alias
        self.visits = visits
        self.ownOpens = ownOpens
        self.lastSeen = lastSeen
    }

    /// The URL actually handed to the default browser, or the bundle path for an application.
    public var openTarget: String {
        switch kind {
        case .history:
            return origin ?? "https://\(host)"
        case .bookmark, .manual:
            return url ?? origin ?? "https://\(host)"
        case .app:
            return url ?? ""
        case .folder:
            return url ?? ""
        case .file:
            return url ?? ""
        }
    }

    public var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        if let title, !title.isEmpty { return title }
        return host
    }
}

public struct DeepLink: Equatable {
    public let host: String
    public let url: String
    public let title: String?
    public let visits: Int

    public init(host: String, url: String, title: String?, visits: Int) {
        self.host = host
        self.url = url
        self.title = title
        self.visits = visits
    }
}

public struct DeepLinkUpsert: Equatable {
    public let url: String
    public let title: String?
    public let visits: Int

    public init(url: String, title: String?, visits: Int) {
        self.url = url
        self.title = title
        self.visits = visits
    }
}

public struct HistoryUpsert: Equatable {
    public let host: String
    public let origin: String
    public let title: String?
    public let visits: Int
    public let lastSeen: Int64
    public let deepLinks: [DeepLinkUpsert]

    public init(host: String, origin: String, title: String?, visits: Int,
                lastSeen: Int64, deepLinks: [DeepLinkUpsert]) {
        self.host = host
        self.origin = origin
        self.title = title
        self.visits = visits
        self.lastSeen = lastSeen
        self.deepLinks = deepLinks
    }
}

public struct DeepLinkAggregate: Equatable {
    public let url: String
    public let title: String?
    public let visits: Int

    public init(url: String, title: String?, visits: Int) {
        self.url = url
        self.title = title
        self.visits = visits
    }
}

public struct HostAggregate: Equatable {
    public let host: String
    public let origin: String
    public let title: String?
    public let visits: Int
    public let lastSeen: Int64
    public let deepLinks: [DeepLinkAggregate]

    public init(host: String, origin: String, title: String?, visits: Int,
                lastSeen: Int64, deepLinks: [DeepLinkAggregate]) {
        self.host = host
        self.origin = origin
        self.title = title
        self.visits = visits
        self.lastSeen = lastSeen
        self.deepLinks = deepLinks
    }
}

public struct InstalledApp: Equatable {
    public let bundleID: String?
    public let name: String
    public let path: String

    public init(bundleID: String?, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

public struct StoredApp: Equatable {
    public let id: Int64
    public let bundleID: String?
    public let name: String
    public let path: String
    public let ownOpens: Int

    public init(id: Int64, bundleID: String?, name: String, path: String, ownOpens: Int) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.ownOpens = ownOpens
    }
}

public struct FolderCandidate: Equatable {
    /// Lowercased canonical path; the dedupe key.
    public let key: String
    /// Canonical full path as displayed and opened.
    public let path: String
    public let name: String
    public let visits: Int
    public let lastSeen: Int64
    public let sources: [String]

    public init(key: String, path: String, name: String, visits: Int, lastSeen: Int64, sources: [String]) {
        self.key = key
        self.path = path
        self.name = name
        self.visits = visits
        self.lastSeen = lastSeen
        self.sources = sources
    }
}

public struct StoredFolder: Equatable {
    public let id: Int64
    public let path: String
    public let name: String
    public let visits: Int
    public let ownOpens: Int
    public let lastSeen: Int64
    public let sources: [String]

    public init(id: Int64, path: String, name: String, visits: Int, ownOpens: Int,
                lastSeen: Int64, sources: [String]) {
        self.id = id
        self.path = path
        self.name = name
        self.visits = visits
        self.ownOpens = ownOpens
        self.lastSeen = lastSeen
        self.sources = sources
    }
}

public struct FileCandidate: Equatable {
    /// Lowercased canonical path; the dedupe key.
    public let key: String
    /// Canonical full path as displayed and opened.
    public let path: String
    public let name: String
    /// Usage signal carried by the source (currently 0; EasyFind opens live in `own_opens`).
    public let visits: Int
    public let lastSeen: Int64
    /// `scan` for indexed directories, `recent` for the system recent-documents list.
    public let sources: [String]

    public init(key: String, path: String, name: String, visits: Int, lastSeen: Int64, sources: [String]) {
        self.key = key
        self.path = path
        self.name = name
        self.visits = visits
        self.lastSeen = lastSeen
        self.sources = sources
    }
}

public struct StoredFile: Equatable {
    public let id: Int64
    public let path: String
    public let name: String
    public let visits: Int
    public let ownOpens: Int
    public let lastSeen: Int64
    public let sources: [String]

    public init(id: Int64, path: String, name: String, visits: Int, ownOpens: Int,
                lastSeen: Int64, sources: [String]) {
        self.id = id
        self.path = path
        self.name = name
        self.visits = visits
        self.ownOpens = ownOpens
        self.lastSeen = lastSeen
        self.sources = sources
    }
}

public struct StoreSnapshot {
    public let entries: [Entry]
    public let deepLinks: [DeepLink]
    public let apps: [StoredApp]
    public let folders: [StoredFolder]
    public let files: [StoredFile]

    public init(entries: [Entry], deepLinks: [DeepLink], apps: [StoredApp] = [],
                folders: [StoredFolder] = [], files: [StoredFile] = []) {
        self.entries = entries
        self.deepLinks = deepLinks
        self.apps = apps
        self.folders = folders
        self.files = files
    }
}

public enum URLTools {
    /// Accepts a URL with or without a scheme; only http/https survive.
    public static func normalizedURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else { return nil }
        return components.string
    }

    public static func host(of url: String) -> String? {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    public static func origin(of url: String) -> String? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else { return nil }
        var origin = "\(scheme)://\(host.lowercased())"
        if let port = components.port,
           !(scheme == "http" && port == 80),
           !(scheme == "https" && port == 443) {
            origin += ":\(port)"
        }
        return origin
    }

    /// Path and fragment only: query strings are tracking noise and never searched.
    public static func searchablePath(of url: String) -> String {
        guard let components = URLComponents(string: url) else { return "" }
        var pieces: [String] = []
        let encodedPath = components.percentEncodedPath
        if !encodedPath.isEmpty {
            pieces.append(encodedPath.removingPercentEncoding ?? encodedPath)
        }
        if let encoded = components.percentEncodedFragment,
           !encoded.isEmpty {
            pieces.append(encoded.removingPercentEncoding ?? encoded)
        }
        return pieces.joined(separator: " ")
    }
}