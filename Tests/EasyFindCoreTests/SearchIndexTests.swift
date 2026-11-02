import XCTest
@testable import EasyFindCore

final class SearchIndexTests: XCTestCase {
    func testCaseInsensitiveHostFragment() {
        let index = SearchIndex()
        index.update(entries: [
            makeEntry(id: 1, kind: .history, host: "github.com", title: "GitHub", visits: 5)
        ], deepLinks: [])

        XCTAssertEqual(index.search("GITH").count, 1)
    }

    func testURLPathFragmentWithTwoTokens() {
        let index = SearchIndex()
        index.update(entries: [
            makeEntry(id: 1, host: "github.com", url: "https://github.com/anthropics/claude-code", title: "Claude Code"),
            makeEntry(id: 2, host: "github.com", url: "https://github.com/anthropics/sdk", title: "SDK")
        ], deepLinks: [])

        let results = index.search("anthropics code")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, 1)
    }

    func testPercentEncodedChinesePathMatchesDecodedText() {
        let index = SearchIndex()
        index.update(entries: [
            makeEntry(id: 1, host: "example.com", url: "https://example.com/%E6%96%87%E6%A1%A3", title: nil)
        ], deepLinks: [])

        XCTAssertEqual(index.search("文档").count, 1)
    }

    func testQueryStringIsNotSearched() {
        let index = SearchIndex()
        index.update(entries: [
            makeEntry(id: 1, host: "example.com", url: "https://example.com/path?utm_source=newsletter", title: "Page")
        ], deepLinks: [])

        XCTAssertEqual(index.search("newsletter").count, 0)
        XCTAssertEqual(index.search("path").count, 1)
    }

    func testExactHostRanksFirst() {
        let index = SearchIndex()
        index.update(entries: [
            makeEntry(id: 1, kind: .history, host: "example.com", title: "github.com docs", visits: 500),
            makeEntry(id: 2, kind: .history, host: "github.com", title: "GitHub", visits: 1)
        ], deepLinks: [])

        let results = index.search("github.com")
        XCTAssertEqual(results.first?.id, 2)
    }

    func testEmptyQueryOrdering() {
        let index = SearchIndex()
        index.update(entries: [
            makeEntry(id: 1, kind: .manual, host: "a.com", url: "https://a.com", title: "A", lastSeen: 50),
            makeEntry(id: 2, kind: .manual, host: "b.com", url: "https://b.com", title: "B", lastSeen: 100),
            makeEntry(id: 3, kind: .history, host: "c.com", title: "C", visits: 5, lastSeen: 1),
            makeEntry(id: 4, kind: .history, host: "d.com", title: "D", visits: 20, lastSeen: 1),
            makeEntry(id: 5, kind: .bookmark, host: "e.com", url: "https://e.com", title: "E")
        ], deepLinks: [])

        XCTAssertEqual(index.defaultEntries().map(\.id), [2, 1, 4, 3])
    }

    func testDeepLinkIsHiddenFromEmptyListButSearchable() {
        let index = SearchIndex()
        index.update(entries: [
            makeEntry(id: 1, kind: .history, host: "github.com", title: "GitHub", visits: 5)
        ], deepLinks: [
            DeepLink(host: "github.com", url: "https://github.com/anthropics/claude-code",
                     title: "Claude Code", visits: 9)
        ])

        XCTAssertEqual(index.defaultEntries().count, 1)
        let results = index.search("anthropics")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.isDeepLink == true)
        XCTAssertEqual(results.first?.openTarget, "https://github.com/anthropics/claude-code")
    }

    func testAliasIsSearchable() {
        let index = SearchIndex()
        index.update(entries: [
            makeEntry(id: 1, kind: .manual, host: "example.com", url: "https://example.com/docs", alias: "API 文档")
        ], deepLinks: [])

        XCTAssertEqual(index.search("API").count, 1)
    }

    func testApplicationNameAndBundleIdentifierAreSearchable() {
        let index = SearchIndex()
        index.update(entries: [], deepLinks: [], apps: [
            StoredApp(id: 10, bundleID: "com.apple.Safari", name: "Safari",
                      path: "/Applications/Safari.app", ownOpens: 3)
        ])

        let byName = index.search("safari")
        XCTAssertEqual(byName.count, 1)
        XCTAssertEqual(byName.first?.kind, .app)
        XCTAssertEqual(byName.first?.openTarget, "/Applications/Safari.app")
        XCTAssertEqual(byName.first?.visits, 3)
        XCTAssertEqual(index.search("com.apple.safari").count, 1)
        XCTAssertTrue(index.defaultEntries().isEmpty)
    }

    func testApplicationExactNameRanksAboveHostPrefix() {
        let index = SearchIndex()
        index.update(
            entries: [
                makeEntry(id: 1, kind: .history, host: "safari.example.com", title: "Safari news", visits: 100)
            ],
            deepLinks: [],
            apps: [
                StoredApp(id: 2, bundleID: "com.apple.Safari", name: "Safari",
                          path: "/Applications/Safari.app", ownOpens: 0)
            ]
        )

        XCTAssertEqual(index.search("safari").first?.kind, .app)
    }

    func testApplicationRequiresEveryToken() {
        let index = SearchIndex()
        index.update(entries: [], deepLinks: [], apps: [
            StoredApp(id: 3, bundleID: "com.github.GitHubClient", name: "GitHub Desktop",
                      path: "/Applications/GitHub Desktop.app", ownOpens: 0)
        ])

        XCTAssertEqual(index.search("github desktop").count, 1)
        XCTAssertEqual(index.search("github slack").count, 0)
    }

    func testFolderNameAndFullPathAreSearchable() {
        let index = SearchIndex()
        index.update(
            entries: [
                makeEntry(id: 1, kind: .history, host: "example.com", title: "Example", visits: 5)
            ],
            deepLinks: [],
            folders: [
                StoredFolder(id: 10, path: "/Users/admin/mytools", name: "mytools",
                             visits: 3, ownOpens: 1, lastSeen: 100, sources: ["shell"]),
                StoredFolder(id: 11, path: "/Users/admin/Downloads", name: "Downloads",
                             visits: 1, ownOpens: 0, lastSeen: 50, sources: ["finder"])
            ]
        )

        XCTAssertEqual(index.search("mytools").first?.kind, .folder)
        XCTAssertEqual(index.search("mytools").first?.openTarget, "/Users/admin/mytools")
        XCTAssertEqual(index.search("admin/mytools").first?.kind, .folder)
        XCTAssertFalse(index.defaultEntries().contains { $0.kind == .folder })
    }

    func testTildeModeListsOnlyFolders() {
        let index = SearchIndex()
        index.update(
            entries: [
                makeEntry(id: 1, kind: .history, host: "example.com", title: "Example", visits: 5)
            ],
            deepLinks: [],
            folders: [
                StoredFolder(id: 10, path: "/Users/admin/mytools", name: "mytools",
                             visits: 3, ownOpens: 1, lastSeen: 100, sources: ["shell"]),
                StoredFolder(id: 11, path: "/Users/admin/Downloads", name: "Downloads",
                             visits: 1, ownOpens: 0, lastSeen: 50, sources: ["finder"])
            ]
        )

        let all = index.search("~")
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.kind == .folder })
        XCTAssertEqual(index.search("~downloads").map(\.id), [11])
    }

    func testFolderRankingUsesVisitsAndOpens() {
        let index = SearchIndex()
        index.update(entries: [], deepLinks: [], folders: [
            StoredFolder(id: 1, path: "/tmp/one", name: "one", visits: 1, ownOpens: 0,
                         lastSeen: 10, sources: ["shell"]),
            StoredFolder(id: 2, path: "/tmp/two", name: "two", visits: 5, ownOpens: 0,
                         lastSeen: 10, sources: ["shell"])
        ])

        XCTAssertEqual(index.search("~").map(\.id), [2, 1])
    }
}