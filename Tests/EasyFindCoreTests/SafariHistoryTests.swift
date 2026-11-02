import Darwin
import XCTest
@testable import EasyFindCore

final class SafariHistoryTests: XCTestCase {
    func testReaderUsesLatestVisitTitleAndEpoch() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("History.db")

        try TestSupport.makeSafariHistoryDatabase(at: databaseURL, items: [
            SafariFixtureItem(url: "https://github.com/a", visitCount: 5, visits: [
                SafariFixtureVisit(title: "Old", time: 700_000_000),
                SafariFixtureVisit(title: "New", time: 700_000_100)
            ])
        ])

        let rows = try SafariHistoryReader.readRows(at: databaseURL.path)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "New")
        XCTAssertEqual(rows[0].visitCount, 5)
        XCTAssertEqual(rows[0].lastVisitTime, 700_000_100 + SafariHistoryReader.epochOffsetSeconds)
    }

    func testReaderFallsBackWithoutVisitTitles() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("History.db")

        try TestSupport.makeSafariHistoryDatabaseWithoutTitles(
            at: databaseURL,
            urls: ["https://example.com/"]
        )

        let rows = try SafariHistoryReader.readRows(at: databaseURL.path)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].title)
        XCTAssertEqual(rows[0].lastVisitTime, 0)
    }

    func testCollectorAggregates() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("History.db")

        try TestSupport.makeSafariHistoryDatabase(at: databaseURL, items: [
            SafariFixtureItem(url: "https://github.com/a", visitCount: 5, visits: [
                SafariFixtureVisit(title: "Repo", time: 700_000_000)
            ]),
            SafariFixtureItem(url: "https://github.com/b", visitCount: 2, visits: [
                SafariFixtureVisit(title: "Issue", time: 700_000_200)
            ])
        ])

        let aggregates = SafariHistoryCollector(databaseURL: databaseURL, label: "Safari").collect()
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?.host, "github.com")
        XCTAssertEqual(aggregates.first?.visits, 7)
    }

    func testPermissionClassification() {
        XCTAssertTrue(BrowserHistoryError.isPermissionDenied(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        ))
        XCTAssertTrue(BrowserHistoryError.isPermissionDenied(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        ))
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let copyError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        XCTAssertTrue(BrowserHistoryError.isPermissionDenied(copyError))
        XCTAssertFalse(BrowserHistoryError.isPermissionDenied(NSError(domain: "example", code: 1)))
    }
}