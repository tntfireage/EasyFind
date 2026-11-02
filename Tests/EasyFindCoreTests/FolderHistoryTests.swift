import XCTest
@testable import EasyFindCore

final class FolderHistoryTests: XCTestCase {
    func testCanonicalDirectoryResolvesSymlinksTrailingSlashAndMissingPaths() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let canonical = try XCTUnwrap(FolderHistoryScanner.canonicalDirectory(link.path))
        XCTAssertEqual(canonical, real.resolvingSymlinksInPath().path)
        XCTAssertEqual(FolderHistoryScanner.canonicalDirectory(real.path + "/"), canonical)
        XCTAssertNil(FolderHistoryScanner.canonicalDirectory(root.appendingPathComponent("missing").path))
        XCTAssertNil(FolderHistoryScanner.canonicalDirectory(root.appendingPathComponent("not-a-dir").path))
    }

    func testCanonicalDirectoryRejectsPackages() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertNil(FolderHistoryScanner.canonicalDirectory(bundle.path))
    }

    func testZshParserAcceptsAbsoluteAndTildeOnly() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = root.appendingPathComponent("alpha", isDirectory: true)
        let beta = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)

        let history = root.appendingPathComponent("history")
        var data = Data()
        data.append(contentsOf: "cd \(alpha.path)\n".utf8)
        data.append(contentsOf: "cd \"\(alpha.path)\"\n".utf8)
        data.append(contentsOf: "cd \(beta.path) && echo done\n".utf8)
        data.append(contentsOf: "cd ..\ncd -\ncd relative/path\n".utf8)
        data.append(contentsOf: ": 1700000000:0;cd \(beta.path)\n".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x0A]) // invalid UTF-8 line must not abort
        data.append(contentsOf: "cd \(alpha.path)\n".utf8)
        try data.write(to: history)

        let candidates = FolderHistoryScanner.parseZshHistory(at: history, now: 1_700_000_000)
        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0.visits) })
        XCTAssertEqual(byPath[alpha.resolvingSymlinksInPath().path], 3)
        XCTAssertEqual(byPath[beta.resolvingSymlinksInPath().path], 2)
        XCTAssertEqual(candidates.count, 2)
    }

    func testEditorRecentsYieldFoldersAndFileParents() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("project", isDirectory: true)
        let fileParent = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fileParent, withIntermediateDirectories: true)
        let file = fileParent.appendingPathComponent("main.swift")
        try Data("x".utf8).write(to: file)

        let databaseURL = root.appendingPathComponent("state.vscdb")
        let expected: [[String: Any]] = [
            ["folderUri": folder.absoluteString],
            ["fileUri": file.absoluteString],
            ["folderUri": root.appendingPathComponent("missing").absoluteString]
        ]
        let payload: [String: Any] = ["entries": expected]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        do {
            let database = try SQLiteDatabase(path: databaseURL.path)
            try database.exec("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value)")
            let statement = try database.prepare("INSERT INTO ItemTable (key, value) VALUES (?, ?)")
            statement.bind(1, "history.recentlyOpenedPathsList")
            statement.bind(2, json)
            _ = try statement.step()
        }

        let candidates = FolderHistoryScanner.scan(
            zshHistoryURLs: [],
            editorStateURLs: [databaseURL],
            includeFinder: false
        )
        let paths = Set(candidates.map(\.path))
        XCTAssertTrue(paths.contains(folder.resolvingSymlinksInPath().path))
        XCTAssertTrue(paths.contains(fileParent.resolvingSymlinksInPath().path))
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.sources == ["code"] })
    }

    func testFinderBookmarksResolve() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("recent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let candidates = FolderHistoryScanner.parseFinderItems(
            [["name": "recent", "file-bookmark": bookmark]],
            now: 1_234
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.path, FolderHistoryScanner.canonicalDirectory(folder.path))
        XCTAssertEqual(candidates.first?.lastSeen, 1_234)
    }

    func testSourcesMergeIntoOneCanonicalEntry() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let history = root.appendingPathComponent("history")
        try Data("cd \(folder.path)\ncd \(folder.path)\n".utf8).write(to: history)

        let databaseURL = root.appendingPathComponent("state.vscdb")
        do {
            let database = try SQLiteDatabase(path: databaseURL.path)
            try database.exec("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value)")
            let json = #"{"entries":[{"folderUri":"\#(folder.absoluteString)"}]}"#
            let statement = try database.prepare("INSERT INTO ItemTable (key, value) VALUES (?, ?)")
            statement.bind(1, "history.recentlyOpenedPathsList")
            statement.bind(2, json)
            _ = try statement.step()
        }

        let candidates = FolderHistoryScanner.scan(
            zshHistoryURLs: [history],
            editorStateURLs: [databaseURL],
            includeFinder: false
        )
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(candidate.visits, 2)
        XCTAssertEqual(candidate.sources, ["code", "shell"])
    }
}