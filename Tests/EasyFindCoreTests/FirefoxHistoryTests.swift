import XCTest
@testable import EasyFindCore

final class FirefoxHistoryTests: XCTestCase {
    func testReaderParsesRowsAndMicrosecondTimestamp() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("places.sqlite")

        try TestSupport.makeFirefoxProfileDatabase(at: databaseURL, rows: [
            FirefoxFixtureRow(url: "https://github.com/a", title: "Repo", visits: 4,
                              lastVisitMicros: 1_700_000_000_000_000),
            FirefoxFixtureRow(url: "https://example.com/", title: "Example", visits: 1,
                              lastVisitMicros: 0)
        ])

        let rows = try FirefoxHistoryReader.readRows(at: databaseURL.path)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].lastVisitTime, 1_700_000_000)
        XCTAssertEqual(rows[1].lastVisitTime, 0)
        XCTAssertEqual(rows[0].title, "Repo")
    }

    func testCollectorAggregatesByHost() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("p1", isDirectory: true)

        try TestSupport.makeFirefoxProfileDatabase(
            at: profile.appendingPathComponent("places.sqlite"),
            rows: [
                FirefoxFixtureRow(url: "https://github.com/a", title: "A", visits: 3,
                                  lastVisitMicros: 1_000_000),
                FirefoxFixtureRow(url: "https://github.com/b", title: "B", visits: 2,
                                  lastVisitMicros: 2_000_000)
            ]
        )

        let aggregates = FirefoxHistoryCollector(root: root).collect()
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?.host, "github.com")
        XCTAssertEqual(aggregates.first?.visits, 5)
        XCTAssertEqual(aggregates.first?.title, "A")
    }
}