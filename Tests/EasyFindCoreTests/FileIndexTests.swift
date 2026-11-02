import XCTest
@testable import EasyFindCore

final class FileIndexTests: XCTestCase {
    func testStorePreservesOpenCountsAndSources() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let alpha = directory.appendingPathComponent("alpha.txt")
        let beta = directory.appendingPathComponent("beta.txt")
        try Data("a".utf8).write(to: alpha)
        try Data("b".utf8).write(to: beta)

        let alphaPath = try XCTUnwrap(FileScanner.canonicalFile(alpha.path))
        let betaPath = try XCTUnwrap(FileScanner.canonicalFile(beta.path))

        try store.replaceFiles([
            fileCandidate(path: alphaPath, visits: 2, lastSeen: 100, sources: ["scan"]),
            fileCandidate(path: betaPath, visits: 1, lastSeen: 50, sources: ["recent"])
        ])

        var files = try store.snapshot().files
        XCTAssertEqual(files.count, 2)

        let alphaEntry = try XCTUnwrap(files.first { $0.path == alphaPath })
        try store.recordFileOpen(id: alphaEntry.id)

        try store.replaceFiles([
            fileCandidate(path: alphaPath, visits: 5, lastSeen: 300, sources: ["recent"])
        ])

        files = try store.snapshot().files
        let refreshed = try XCTUnwrap(files.first { $0.path == alphaPath })
        XCTAssertEqual(refreshed.ownOpens, 1)
        XCTAssertEqual(refreshed.visits, 5)
        XCTAssertGreaterThanOrEqual(refreshed.lastSeen, 300)
        XCTAssertEqual(refreshed.sources, ["recent", "scan"])

        try store.clearFiles()
        XCTAssertTrue(try store.snapshot().files.isEmpty)
    }

    func testStoreSnapshotFiltersMissingFiles() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("existing.txt")
        try Data("a".utf8).write(to: existing)
        let missing = directory.appendingPathComponent("missing.txt")

        try store.replaceFiles([
            fileCandidate(path: existing.path, visits: 1, lastSeen: 1, sources: ["scan"]),
            fileCandidate(path: missing.path, visits: 1, lastSeen: 1, sources: ["scan"])
        ])

        let files = try store.snapshot().files
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, existing.resolvingSymlinksInPath().path)
    }

    func testSearchIndexFindsFilesAndSupportsFileFilter() {
        let index = SearchIndex()
        index.update(entries: [], deepLinks: [], files: [
            StoredFile(id: 1, path: "/Users/me/Documents/report.pdf", name: "report.pdf",
                       visits: 0, ownOpens: 7, lastSeen: 10, sources: ["scan"]),
            StoredFile(id: 2, path: "/Users/me/Downloads/photo.png", name: "photo.png",
                       visits: 0, ownOpens: 0, lastSeen: 20, sources: ["recent"])
        ])

        XCTAssertEqual(index.search("report").map(\.id), [1])
        XCTAssertEqual(index.search("documents pdf").map(\.id), [1])
        XCTAssertTrue(index.search("report").allSatisfy { $0.kind == .file })

        let fileOnly = index.search("@")
        XCTAssertEqual(fileOnly.map(\.id), [1, 2])
        XCTAssertTrue(fileOnly.allSatisfy { $0.kind == .file })

        XCTAssertEqual(index.search("@ photo").map(\.id), [2])
        XCTAssertEqual(index.search("@ missing").count, 0)
    }

    func testDefaultEntriesIncludeMostUsedFilesBeforeHistory() {
        let index = SearchIndex()
        index.update(
            entries: [makeEntry(id: 9, kind: .history, host: "example.com", visits: 100)],
            deepLinks: [],
            files: [
                StoredFile(id: 1, path: "/tmp/a.txt", name: "a.txt", visits: 0, ownOpens: 1,
                           lastSeen: 10, sources: ["scan"]),
                StoredFile(id: 2, path: "/tmp/b.txt", name: "b.txt", visits: 0, ownOpens: 5,
                           lastSeen: 20, sources: ["scan"])
            ]
        )

        XCTAssertEqual(index.defaultEntries().map(\.id), [2, 1, 9])
    }

    func testConfigurationDefaultsAndSanitization() {
        XCTAssertTrue(Configuration.default.sync.files)
        XCTAssertEqual(Configuration.default.files.directories, FileSearchConfig.defaultDirectories)
        XCTAssertEqual(Configuration.default.files.maxFiles, 20_000)
        XCTAssertFalse(Configuration.default.files.includeHidden)
        XCTAssertEqual(Configuration.default.actions.file.commandEnter, "finder")

        let configuration = Configuration.default
        var raw = configuration
        raw.files.directories = ["relative/path", "/tmp/dup", "/tmp/dup", "~/Docs"]
        raw.files.maxFiles = 1
        let sanitized = ConfigurationLoader.sanitize(raw)

        XCTAssertEqual(sanitized.files.directories, ["/tmp/dup", "~/Docs"])
        XCTAssertEqual(sanitized.files.maxFiles, 100)
    }

    func testLegacyConfigGainsFileDefaults() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("config.json")
        try Data(#"{ "language": "en" }"#.utf8).write(to: url)

        let configuration = ConfigurationLoader.load(from: url)
        XCTAssertTrue(configuration.sync.files)
        XCTAssertEqual(configuration.files.directories, FileSearchConfig.defaultDirectories)
        XCTAssertFalse(configuration.files.includeHidden)
        XCTAssertEqual(configuration.actions.file.enter, "open")
    }

    func testScannedDirectoriesAreStoredAsFolders() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let alpha = directory.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)

        let result = FileScanner.scanAll(directories: [directory.path], maxFiles: 100)
        try store.replaceFolders(result.directories)

        let folders = try store.snapshot().folders
        let entry = try XCTUnwrap(folders.first { $0.name == "alpha" })
        XCTAssertEqual(entry.sources, ["scan"])
        XCTAssertEqual(entry.visits, 0)
    }

    private func fileCandidate(path: String, visits: Int, lastSeen: Int64, sources: [String]) -> FileCandidate {
        let canonical = FileScanner.canonicalFile(path) ?? path
        return FileCandidate(
            key: canonical.lowercased(),
            path: canonical,
            name: (canonical as NSString).lastPathComponent,
            visits: visits,
            lastSeen: lastSeen,
            sources: sources
        )
    }
}
