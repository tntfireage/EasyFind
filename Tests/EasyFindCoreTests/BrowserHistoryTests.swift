import XCTest
@testable import EasyFindCore

final class BrowserHistoryTests: XCTestCase {
    func testDiscoveryFindsInstalledBrowsers() throws {
        let home = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)

        try TestSupport.makeChromeProfileDatabase(
            at: appSupport.appendingPathComponent("Google/Chrome/Default/History"),
            rows: []
        )
        try TestSupport.makeChromeProfileDatabase(
            at: appSupport.appendingPathComponent("BraveSoftware/Brave-Browser/Default/History"),
            rows: []
        )
        try TestSupport.makeFirefoxProfileDatabase(
            at: appSupport.appendingPathComponent("Firefox/Profiles/p1/places.sqlite"),
            rows: []
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Safari", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: home.appendingPathComponent("Library/Safari/History.db").path,
            contents: Data()
        )

        let ids = Set(BrowserHistoryDiscovery.sources(home: home).map(\.id))
        XCTAssertTrue(ids.contains("chrome"))
        XCTAssertTrue(ids.contains("brave"))
        XCTAssertTrue(ids.contains("firefox"))
        XCTAssertTrue(ids.contains("safari"))
        XCTAssertFalse(ids.contains("edge"))
    }

    func testCompositeCollectorMergesAcrossBrowsers() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try TestSupport.makeChromeProfileDatabase(
            at: root.appendingPathComponent("Chrome/Default/History"),
            rows: [
                FixtureRow(url: "https://github.com/a", title: "Chrome Repo", visits: 10, unixTime: 1_000)
            ]
        )
        try TestSupport.makeFirefoxProfileDatabase(
            at: root.appendingPathComponent("Firefox/Profiles/p1/places.sqlite"),
            rows: [
                FirefoxFixtureRow(url: "https://github.com/b", title: "Firefox Issue", visits: 5,
                                  lastVisitMicros: 2_000_000_000)
            ]
        )
        let safariDatabase = root.appendingPathComponent("Safari/History.db")
        try TestSupport.makeSafariHistoryDatabase(at: safariDatabase, items: [
            SafariFixtureItem(url: "https://github.com/c", visitCount: 3, visits: [
                SafariFixtureVisit(title: "Safari Page", time: 700_000_000)
            ])
        ])

        let collector = BrowserHistoryCollector(sources: [
            BrowserHistorySource(
                id: "chrome", name: "Chrome", family: .chromium,
                root: root.appendingPathComponent("Chrome")
            ),
            BrowserHistorySource(
                id: "firefox", name: "Firefox", family: .firefox,
                root: root.appendingPathComponent("Firefox/Profiles")
            ),
            BrowserHistorySource(
                id: "safari", name: "Safari", family: .safari,
                root: safariDatabase
            )
        ])

        let aggregates = collector.collect()
        XCTAssertEqual(aggregates.count, 1)
        let github = try XCTUnwrap(aggregates.first)
        XCTAssertEqual(github.host, "github.com")
        XCTAssertEqual(github.visits, 18)
        XCTAssertEqual(github.deepLinks.count, 3)
        XCTAssertEqual(github.deepLinks.first?.visits, 10)
    }

    func testSafariPermissionIsDetected() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Safari", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("History.db")
        try TestSupport.makeSafariHistoryDatabase(at: databaseURL, items: [])

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
        }

        let collector = SafariHistoryCollector(databaseURL: databaseURL, label: "Safari")
        _ = collector.collect()
        XCTAssertTrue(collector.permissionDenied)
    }
}