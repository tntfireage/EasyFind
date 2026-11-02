import XCTest
@testable import EasyFindCore

final class AppScannerTests: XCTestCase {
    func testReadsDisplayNameAndBundleIdentifier() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("Safari.app")
        try TestSupport.makeAppBundle(
            at: appURL,
            name: "Safari",
            bundleID: "com.apple.Safari",
            displayName: "Safari Browser"
        )

        let apps = AppScanner.scan(roots: [root])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.name, "Safari Browser")
        XCTAssertEqual(apps.first?.bundleID, "com.apple.Safari")
        XCTAssertEqual(apps.first?.path, appURL.resolvingSymlinksInPath().path)
    }

    func testFallsBackToFilenameWhenNamesAreMissing() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try TestSupport.makeAppBundle(
            at: root.appendingPathComponent("Plain.app"),
            name: "Plain",
            bundleID: "com.example.plain",
            bundleName: ""
        )

        let apps = AppScanner.scan(roots: [root])
        XCTAssertEqual(apps.first?.name, "Plain")
    }

    func testDeduplicatesByBundleIdentifierPreferringEarlierRoot() throws {
        let preferred = try TestSupport.temporaryDirectory()
        let secondary = try TestSupport.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: preferred)
            try? FileManager.default.removeItem(at: secondary)
        }

        try TestSupport.makeAppBundle(
            at: preferred.appendingPathComponent("Chrome.app"),
            name: "Chrome",
            bundleID: "com.google.Chrome"
        )
        try TestSupport.makeAppBundle(
            at: secondary.appendingPathComponent("Chrome.app"),
            name: "Chrome",
            bundleID: "com.google.Chrome"
        )

        let apps = AppScanner.scan(roots: [preferred, secondary])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(
            apps.first?.path,
            preferred.appendingPathComponent("Chrome.app").resolvingSymlinksInPath().path
        )
    }

    func testIgnoresNestedBundlesAndNonBundles() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let outer = root.appendingPathComponent("Outer.app")
        try TestSupport.makeAppBundle(at: outer, name: "Outer", bundleID: "com.example.outer")

        let helper = outer.appendingPathComponent("Contents/Frameworks/Helper.app")
        try TestSupport.makeAppBundle(at: helper, name: "Helper", bundleID: "com.example.helper")

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("PlainFolder"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("README.txt").path,
            contents: Data("not an app".utf8)
        )

        let apps = AppScanner.scan(roots: [root])
        XCTAssertEqual(apps.map(\.name), ["Outer"])
    }

    func testSkipsBundlesWithoutExecutable() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try TestSupport.makeAppBundle(
            at: root.appendingPathComponent("Broken.app"),
            name: "Broken",
            bundleID: "com.example.broken",
            executable: false
        )

        XCTAssertTrue(AppScanner.scan(roots: [root]).isEmpty)
    }
}