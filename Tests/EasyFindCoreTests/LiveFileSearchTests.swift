import XCTest
@testable import EasyFindCore

final class LiveFileSearchTests: XCTestCase {
    func testFindsFilesOutsideIndexedDirectoriesAndFiltersNoise() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("project", isDirectory: true)
        let hidden = project.appendingPathComponent(".hidden", isDirectory: true)
        let noise = project.appendingPathComponent("node_modules/pkg", isDirectory: true)
        for directory in [project, hidden, noise] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let visible = project.appendingPathComponent("install.sh")
        let hiddenFile = hidden.appendingPathComponent("install.sh")
        let noiseFile = noise.appendingPathComponent("install.sh")
        for file in [visible, hiddenFile, noiseFile] {
            try Data("#!/bin/sh\n".utf8).write(to: file)
        }

        let paths = [visible.path, hiddenFile.path, noiseFile.path, "/System/install.sh"]
        let results = LiveFileSearch.search(
            query: "install.sh",
            allowedRoots: [root.path],
            runner: { _, _ in paths }
        )

        XCTAssertEqual(results.map(\.openTarget), [visible.resolvingSymlinksInPath().path])
        XCTAssertEqual(results.first?.kind, .file)
    }

    func testIncludeHiddenEnablesDotfiles() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let hidden = root.appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let file = hidden.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: file)

        let off = LiveFileSearch.search(query: "settings", allowedRoots: [root.path],
                                        runner: { _, _ in [file.path] })
        XCTAssertTrue(off.isEmpty)

        let on = LiveFileSearch.search(query: "settings", includeHidden: true,
                                       allowedRoots: [root.path],
                                       runner: { _, _ in [file.path] })
        XCTAssertEqual(on.map(\.openTarget), [file.resolvingSymlinksInPath().path])
    }

    func testFindsDirectoriesAndHonorsMode() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = root.appendingPathComponent("bcmm-core", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let any = LiveFileSearch.search(query: "bcmm-core", allowedRoots: [root.path],
                                        runner: { _, _ in [directory.path] })
        XCTAssertEqual(any.count, 1)
        XCTAssertEqual(any.first?.kind, .folder)

        let filesOnly = LiveFileSearch.search(query: "bcmm-core", mode: .files,
                                              allowedRoots: [root.path],
                                              runner: { _, _ in [directory.path] })
        XCTAssertTrue(filesOnly.isEmpty)

        let foldersOnly = LiveFileSearch.search(query: "bcmm-core", mode: .folders,
                                                allowedRoots: [root.path],
                                                runner: { _, _ in [directory.path] })
        XCTAssertEqual(foldersOnly.count, 1)
    }

    func testAllTokensMustMatchThePath() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("install.sh")
        let other = root.appendingPathComponent("install.md")
        try Data("x".utf8).write(to: file)
        try Data("y".utf8).write(to: other)

        let results = LiveFileSearch.search(query: "install sh", allowedRoots: [root.path],
                                            runner: { _, _ in [file.path, other.path] })
        XCTAssertEqual(results.map(\.openTarget), [file.resolvingSymlinksInPath().path])
    }

    func testExactNameRanksBeforePrefixedName() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let exact = root.appendingPathComponent("report.pdf")
        let prefixed = root.appendingPathComponent("report-final.pdf")
        try Data("a".utf8).write(to: exact)
        try Data("b".utf8).write(to: prefixed)

        let results = LiveFileSearch.search(query: "report.pdf", allowedRoots: [root.path],
                                            runner: { _, _ in [prefixed.path, exact.path] })
        XCTAssertEqual(results.first?.openTarget, exact.resolvingSymlinksInPath().path)
    }
}
