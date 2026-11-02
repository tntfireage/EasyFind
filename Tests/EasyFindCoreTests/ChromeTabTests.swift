import XCTest
@testable import EasyFindCore

private struct FakeRunningProvider: ChromeRunningProviding {
    let running: Bool
    func isChromeRunning() -> Bool { running }
}

final class ChromeTabTests: XCTestCase {
    func testParserHandlesTitlesTabsAndInvalidLines() {
        let output = """
        GitHub\thttps://github.com
        Claude\t\thttps://claude.ai
        not a valid line
        Tabbed\tTitle\thttps://example.com/x
        JavaScript\tjavascript:alert(1)
        """

        let tabs = ChromeTabParser.parse(output)
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs[0].title, "GitHub")
        XCTAssertEqual(tabs[0].url, "https://github.com")
        XCTAssertEqual(tabs[1].url, "https://claude.ai")
        XCTAssertEqual(tabs[2].title, "Tabbed\tTitle")
        XCTAssertEqual(tabs[2].url, "https://example.com/x")
    }

    func testCollectorSkipsWhenChromeIsNotRunning() throws {
        let collector = ChromeTabCollector(
            runningProvider: FakeRunningProvider(running: false),
            runner: {
                XCTFail("the AppleScript runner must not be called when Chrome is not running")
                return ""
            }
        )

        XCTAssertEqual(try collector.collect(), [])
    }

    func testCollectorDeduplicatesByURL() throws {
        let collector = ChromeTabCollector(
            runningProvider: FakeRunningProvider(running: true),
            runner: {
                """
                One\thttps://example.com/a
                Two\thttps://example.com/a
                Three\thttps://example.com/b
                """
            }
        )

        let tabs = try collector.collect()
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[0].url, "https://example.com/a")
        XCTAssertEqual(tabs[0].title, "One")
    }

    func testCollectorPropagatesAuthorizationDenial() {
        let collector = ChromeTabCollector(
            runningProvider: FakeRunningProvider(running: true),
            runner: { throw ChromeTabError.notAuthorized }
        )

        XCTAssertThrowsError(try collector.collect()) { error in
            guard case ChromeTabError.notAuthorized = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRecapturingTabRefreshesTitleWithoutNewRow() throws {
        let (store, directory) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.upsertBookmark(url: "https://example.com/a", title: "Old title", lastSeen: 1)
        try store.upsertBookmark(url: "https://example.com/a", title: "New title", lastSeen: 2)

        let bookmarks = try store.snapshot().entries.filter { $0.kind == .bookmark }
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.title, "New title")
    }
}