import XCTest
@testable import EasyFindCore

final class FileScannerTests: XCTestCase {
    func testScanFindsRegularFilesAndSkipsNoise() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("a".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("b".utf8).write(to: root.appendingPathComponent(".hidden"))

        let nested = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: nested.appendingPathComponent("paper.pdf"))

        let noise = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        try Data("d".utf8).write(to: noise.appendingPathComponent("index.js"))

        try TestSupport.makeAppBundle(
            at: root.appendingPathComponent("Demo.app"),
            name: "Demo",
            bundleID: "com.example.demo"
        )

        let files = FileScanner.scan(directories: [root.path], maxFiles: 100)
        let names = Set(files.map(\.name))

        XCTAssertTrue(names.contains("notes.txt"))
        XCTAssertTrue(names.contains("paper.pdf"))
        XCTAssertFalse(names.contains(".hidden"))
        XCTAssertFalse(names.contains("index.js"))
        XCTAssertFalse(names.contains("Demo"))
        XCTAssertTrue(files.allSatisfy { $0.sources == ["scan"] })
    }

    func testScanHonorsMaxFiles() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<5 {
            try Data("x".utf8).write(to: root.appendingPathComponent("file-\(index).txt"))
        }

        XCTAssertEqual(FileScanner.scan(directories: [root.path], maxFiles: 2).count, 2)
    }

    func testCanonicalFileRequiresExistingRegularFile() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("doc.md")
        try Data("x".utf8).write(to: file)

        XCTAssertEqual(FileScanner.canonicalFile(file.path), file.resolvingSymlinksInPath().path)
        XCTAssertNil(FileScanner.canonicalFile(root.path))
        XCTAssertNil(FileScanner.canonicalFile(root.appendingPathComponent("missing.md").path))
        XCTAssertNil(FileScanner.canonicalFile("relative/path.md"))
    }

    func testSystemPathsAreDeniedButUserToolingIsAllowed() {
        XCTAssertTrue(FileScanner.isDeniedSystemPath("/System/Library/CoreServices"))
        XCTAssertTrue(FileScanner.isDeniedSystemPath("/usr/lib/libz.dylib"))
        XCTAssertTrue(FileScanner.isDeniedSystemPath("/bin/bash"))
        XCTAssertTrue(FileScanner.isDeniedSystemPath("/private/etc/hosts"))
        XCTAssertFalse(FileScanner.isDeniedSystemPath("/usr/local/bin/tool"))
        XCTAssertFalse(FileScanner.isDeniedSystemPath("/opt/homebrew/bin/tool"))
        XCTAssertFalse(FileScanner.isDeniedSystemPath("/Users/someone/Documents/report.pdf"))
    }

    func testCatalogMergeAddsRecencyAndSources() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("report.pdf")
        try Data("x".utf8).write(to: file)
        let canonical = try XCTUnwrap(FileScanner.canonicalFile(file.path))

        let scanned = [FileCandidate(key: canonical.lowercased(), path: canonical, name: "report.pdf",
                                     visits: 0, lastSeen: 10, sources: ["scan"])]
        let recent = [FileCandidate(key: canonical.lowercased(), path: canonical, name: "report.pdf",
                                    visits: 0, lastSeen: 50, sources: ["recent"])]

        let merged = FileCatalog.merge(scanned: scanned, recent: recent, directories: [root.path])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.lastSeen, 50)
        XCTAssertEqual(merged.first?.sources, ["recent", "scan"])
    }

    func testCatalogMergeIgnoresRecentFilesOutsideConfiguredDirectories() throws {
        let root = try TestSupport.temporaryDirectory()
        let outside = try TestSupport.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let insideFile = root.appendingPathComponent("inside.txt")
        let outsideFile = outside.appendingPathComponent("outside.txt")
        try Data("a".utf8).write(to: insideFile)
        try Data("b".utf8).write(to: outsideFile)

        let recent = [outsideFile, insideFile].map {
            FileCandidate(key: $0.path.lowercased(), path: $0.path, name: $0.lastPathComponent,
                          visits: 0, lastSeen: 5, sources: ["recent"])
        }

        let merged = FileCatalog.merge(scanned: [], recent: recent, directories: [root.path])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.path, insideFile.resolvingSymlinksInPath().path)
    }

    func testRecentScannerUsesInjectedProviderAndScopesToDirectories() throws {
        let root = try TestSupport.temporaryDirectory()
        let outside = try TestSupport.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let insideFile = root.appendingPathComponent("recent.md")
        let outsideFile = outside.appendingPathComponent("other.md")
        try Data("a".utf8).write(to: insideFile)
        try Data("b".utf8).write(to: outsideFile)

        let used = Date(timeIntervalSince1970: 1_700_000_000)
        let files = RecentFilesScanner.scan(directories: [root.path], limit: 10, provider: { _, _, _ in
            [
                RecentFilesScanner.Item(path: insideFile.path, lastUsed: used),
                RecentFilesScanner.Item(path: outsideFile.path, lastUsed: used)
            ]
        })

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, insideFile.resolvingSymlinksInPath().path)
        XCTAssertEqual(files.first?.lastSeen, Int64(used.timeIntervalSince1970))
        XCTAssertEqual(files.first?.sources, ["recent"])
    }
}
