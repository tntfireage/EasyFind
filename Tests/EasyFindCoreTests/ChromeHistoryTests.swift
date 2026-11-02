import XCTest
@testable import EasyFindCore

final class ChromeHistoryTests: XCTestCase {
    func testProfileDiscoveryFindsOnlyDirectoriesWithHistory() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try TestSupport.makeChromeProfileDatabase(at: root.appendingPathComponent("Default/History"), rows: [])
        try TestSupport.makeChromeProfileDatabase(at: root.appendingPathComponent("Profile 1/History"), rows: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Crashpad"), withIntermediateDirectories: true)

        let profiles = ChromeProfileDiscovery.profiles(root: root)
        XCTAssertEqual(profiles.map(\.name), ["Default", "Profile 1"])
    }

    func testProfileDiscoverySupportsRootLevelHistory() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try TestSupport.makeChromeProfileDatabase(at: root.appendingPathComponent("History"), rows: [])
        let profiles = ChromeProfileDiscovery.profiles(root: root)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.name, root.lastPathComponent)
    }

    func testSnapshotSkipsUnchangedProfilesAndCleansUp() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let historyURL = root.appendingPathComponent("Default/History")
        try TestSupport.makeChromeProfileDatabase(at: historyURL, rows: [
            FixtureRow(url: "https://example.com/", title: "Example", visits: 1)
        ])

        let profile = try XCTUnwrap(ChromeProfileDiscovery.profiles(root: root).first)
        let snapshotter = ChromeHistorySnapshotter(tempRoot: root.appendingPathComponent("snapshots"))

        XCTAssertTrue(snapshotter.refreshNeeded(for: profile))
        let snapshot = try snapshotter.makeSnapshot(for: profile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(snapshotter.refreshNeeded(for: profile))

        let snapshotDirectory = snapshot.deletingLastPathComponent()
        snapshotter.removeSnapshot(at: snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotDirectory.path))

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: profile.historyURL.path
        )
        XCTAssertTrue(snapshotter.refreshNeeded(for: profile))
    }

    func testChromiumTimestampConversion() {
        let unix: Int64 = 1_600_000_000
        let micros = (unix + ChromiumTime.epochOffsetSeconds) * 1_000_000
        XCTAssertEqual(ChromiumTime.unixSeconds(fromChromiumMicroseconds: micros), unix)
    }

    func testAggregateUsesMostVisitedPageForOriginAndTitle() {
        let rows = [
            ChromeHistoryRow(url: "https://github.com/b", title: "Issue", visitCount: 5, lastVisitTime: 200),
            ChromeHistoryRow(url: "https://github.com/a", title: "Repo", visitCount: 20, lastVisitTime: 100),
            ChromeHistoryRow(url: "http://intranet.local/x", title: "Intranet", visitCount: 3, lastVisitTime: 300),
            ChromeHistoryRow(url: "chrome://settings", title: "Settings", visitCount: 99, lastVisitTime: 400)
        ]

        let aggregates = HistoryAggregator.aggregate(rows)
        XCTAssertEqual(aggregates.count, 2)

        let github = aggregates.first { $0.host == "github.com" }
        XCTAssertEqual(github?.visits, 25)
        XCTAssertEqual(github?.origin, "https://github.com")
        XCTAssertEqual(github?.title, "Repo")
        XCTAssertEqual(github?.lastSeen, 200)
        XCTAssertEqual(github?.deepLinks.map(\.url), ["https://github.com/a", "https://github.com/b"])

        let intranet = aggregates.first { $0.host == "intranet.local" }
        XCTAssertEqual(intranet?.origin, "http://intranet.local")
    }

    func testTopFiveDeepLinksPerHost() {
        let rows = (1...7).map {
            ChromeHistoryRow(
                url: "https://many.example/p\($0)",
                title: "P\($0)",
                visitCount: $0,
                lastVisitTime: Int64($0)
            )
        }

        let aggregate = HistoryAggregator.aggregate(rows).first
        XCTAssertEqual(aggregate?.deepLinks.count, 5)
        XCTAssertEqual(aggregate?.deepLinks.map(\.visits), [7, 6, 5, 4, 3])
    }

    func testCollectorMergesProfilesBySummingVisits() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try TestSupport.makeChromeProfileDatabase(at: root.appendingPathComponent("Default/History"), rows: [
            FixtureRow(url: "https://github.com/a", title: "Repo", visits: 10, unixTime: 1_000)
        ])
        try TestSupport.makeChromeProfileDatabase(at: root.appendingPathComponent("Profile 1/History"), rows: [
            FixtureRow(url: "https://github.com/b", title: "Issue", visits: 5, unixTime: 2_000)
        ])

        let collector = ChromeHistoryCollector(root: root)
        let aggregates = try collector.collect()

        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?.host, "github.com")
        XCTAssertEqual(aggregates.first?.visits, 15)
    }

    func testClearedFixtureHistoryKeepsArchiveUnchanged() throws {
        let root = try TestSupport.temporaryDirectory()
        let storeDirectory = try TestSupport.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        let historyURL = root.appendingPathComponent("Default/History")
        try TestSupport.makeChromeProfileDatabase(at: historyURL, rows: [
            FixtureRow(url: "https://github.com/a", title: "Repo", visits: 10, unixTime: 1_000),
            FixtureRow(url: "https://github.com/b", title: "Issue", visits: 4, unixTime: 2_000)
        ])

        let collector = ChromeHistoryCollector(root: root)
        let store = try Store(path: storeDirectory.appendingPathComponent("easyfind.db").path)

        try store.upsertHistory(upserts(from: collector.collect()))
        let before = try store.snapshot()
        XCTAssertFalse(before.entries.isEmpty)

        try FileManager.default.removeItem(at: historyURL)
        try TestSupport.makeChromeProfileDatabase(at: historyURL, rows: [])

        let cleared = try collector.collect()
        XCTAssertTrue(cleared.isEmpty)
        try store.upsertHistory(upserts(from: cleared))

        let after = try store.snapshot()
        XCTAssertEqual(before.entries, after.entries)
        XCTAssertEqual(before.deepLinks, after.deepLinks)
    }

    private func upserts(from aggregates: [HostAggregate]) -> [HistoryUpsert] {
        aggregates.map { aggregate in
            HistoryUpsert(
                host: aggregate.host,
                origin: aggregate.origin,
                title: aggregate.title,
                visits: aggregate.visits,
                lastSeen: aggregate.lastSeen,
                deepLinks: aggregate.deepLinks.map {
                    DeepLinkUpsert(url: $0.url, title: $0.title, visits: $0.visits)
                }
            )
        }
    }
}