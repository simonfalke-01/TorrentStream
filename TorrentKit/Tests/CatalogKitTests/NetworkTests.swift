import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CatalogKit

final class NetworkTests: XCTestCase {
    private func response(status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://graphql.anilist.co")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testBudgetHoldsReserveForViewer() async throws {
        let budget = AniListBudget()
        XCTAssertNil(budget.spare, "unknown before the first response")
        try await budget.admit(background: true)
        budget.finished(response(status: 200, headers: ["X-RateLimit-Remaining": "\(AniListBudget.reserve + 1)"]))
        XCTAssertEqual(budget.spare, 1)

        try await budget.admit(background: true)
        XCTAssertEqual(budget.spare, 0, "requests in flight count against the budget")
        do {
            try await budget.admit(background: true)
            XCTFail("background request should give way")
        } catch CatalogError.rateLimited {}
        // The viewer's requests still go through.
        try await budget.admit(background: false)
        budget.finished(nil)
        budget.finished(nil)
        XCTAssertEqual(budget.spare, 1)
    }

    func testBudgetRefillsAfterAMinute() {
        let budget = AniListBudget()
        budget.record(remaining: 0, at: Date().addingTimeInterval(-61))
        XCTAssertNil(budget.spare)
        budget.record(remaining: 0, at: Date())
        XCTAssertEqual(budget.spare, -AniListBudget.reserve)
    }

    func testRateLimitBlocksBackgroundAndDelaysViewer() async throws {
        let budget = AniListBudget()
        try await budget.admit(background: false)
        budget.finished(response(status: 429, headers: ["Retry-After": "1"]))
        XCTAssertEqual(budget.spare, 0)
        do {
            try await budget.admit(background: true)
            XCTFail("background request should not wait out a rate limit")
        } catch CatalogError.rateLimited {}
        let started = Date()
        try await budget.admit(background: false)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.5)
    }

    private func show(_ id: Int) -> Show { Show(id: id, title: "S\(id)") }

    func testHedgedPrefersFastPrimary() async throws {
        let catalog = ShowCatalog()
        let calls = Counter()
        let out = try await catalog.hedged(primary: { [self] in [show(1)] },
                                           fallback: { calls.add(); return [Show(id: 2, title: "S2")] },
                                           delay: 0.2, hedgeAllowed: { true })
        XCTAssertEqual(out.map(\.id), [1])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls.value, 0, "a primary answering before the delay doesn't start the fallback")
    }

    func testHedgedUsesFallbackWhenPrimaryIsSlow() async throws {
        let catalog = ShowCatalog()
        let started = Date()
        let out = try await catalog.hedged(primary: {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return [Show(id: 1, title: "S1")]
        }, fallback: { [Show(id: 2, title: "S2")] }, delay: 0.1, hedgeAllowed: { true })
        XCTAssertEqual(out.map(\.id), [2])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the slow primary is cancelled, not awaited")
    }

    func testHedgedWaitsForPrimaryWhenHedgingNotAllowed() async throws {
        let catalog = ShowCatalog()
        let out = try await catalog.hedged(primary: {
            try await Task.sleep(nanoseconds: 300_000_000)
            return [Show(id: 1, title: "S1")]
        }, fallback: { [Show(id: 2, title: "S2")] }, delay: 0.05, hedgeAllowed: { false })
        XCTAssertEqual(out.map(\.id), [1])
    }

    func testHedgedFallsBackWhenPrimaryFails() async throws {
        let catalog = ShowCatalog()
        let out = try await catalog.hedged(primary: { throw CatalogError.unreadable },
                                           fallback: { [Show(id: 2, title: "S2")] }, delay: 10, hedgeAllowed: { false })
        XCTAssertEqual(out.map(\.id), [2])

        do {
            _ = try await catalog.hedged(primary: { throw CatalogError.unreadable },
                                         fallback: { throw CatalogError.http(500) }, delay: 0.01, hedgeAllowed: { true })
            XCTFail("both failed")
        } catch CatalogError.http(500) {}
    }

    /// AniList fills in relations two levels deep only; entries beyond the neighbours come back as ids to fetch in one go.
    func testNodesReadNeighboursAndListSeasonsBeyond() {
        func media(_ id: Int, start: Int, relations: [(String, [String: Any])]) -> [String: Any] {
            [
                "id": id, "format": "TV", "status": "FINISHED", "episodes": 12,
                "title": ["romaji": "Show \(id)"], "startDate": ["year": start],
                "relations": ["edges": relations.map { ["relationType": $0.0, "node": $0.1] }],
            ]
        }
        func stub(_ id: Int, start: Int, format: String = "TV") -> [String: Any] {
            ["id": id, "format": format, "startDate": ["year": start]]
        }
        // 1 <- 2 <- [3] -> 4 -> (5), and a manga linking every season.
        let s2 = media(2, start: 2011, relations: [("PREQUEL", stub(1, start: 2010)), ("SEQUEL", stub(3, start: 2012))])
        let s4 = media(4, start: 2013, relations: [("PREQUEL", stub(3, start: 2012)), ("SEQUEL", stub(5, start: 2014))])
        var manga = media(100, start: 2009, relations: [
            ("ADAPTATION", stub(1, start: 2010)), ("ADAPTATION", stub(5, start: 2014)), ("ADAPTATION", stub(6, start: 2016)),
            ("ADAPTATION", stub(7, start: 2015, format: "MOVIE")),
        ])
        manga["format"] = "MANGA"
        let s3 = media(3, start: 2012, relations: [("PREQUEL", s2), ("SEQUEL", s4), ("ADAPTATION", manga)])

        let (nodes, nearby) = ShowCatalog.nodes(s3)
        XCTAssertEqual(Set(nodes.keys), [2, 3, 4, 100])
        XCTAssertEqual(nodes[3]?.prequel, 2)
        XCTAssertEqual(nodes[3]?.sequel, 4)
        XCTAssertEqual(nodes[2]?.prequel, 1)
        XCTAssertEqual(nodes[4]?.sequel, 5)
        XCTAssertEqual(nearby, [1, 5, 6], "season-like entries not already known, movies left out")

        let start = nodes[3]!
        XCTAssertTrue(ShowCatalog.chainContinues(from: start, known: nodes))
        var all = nodes
        for id in [1, 5] { all[id] = ShowCatalog.node(media(id, start: 2000 + id, relations: [])) }
        XCTAssertFalse(ShowCatalog.chainContinues(from: start, known: all))
    }

    /// Kitsu search lists shows AniList flags adult (Ishuzoku Reviewers); opening one must still load its episodes.
    func testDetailsReadAdultFlaggedShow() {
        let m: [String: Any] = [
            "id": 110270, "format": "TV", "status": "FINISHED", "episodes": 12, "isAdult": true,
            "title": ["romaji": "Ishuzoku Reviewers", "english": "Interspecies Reviewers"],
            "startDate": ["year": 2020], "relations": ["edges": []],
        ]
        XCTAssertNil(ShowCatalog.show(m), "lists keep filtering adult entries")
        let (nodes, _) = ShowCatalog.nodes(m)
        XCTAssertEqual(nodes[110270]?.show.title, "Interspecies Reviewers")
        XCTAssertEqual(nodes[110270]?.show.episodes, 12)
        XCTAssertEqual(nodes[110270]?.show.isAdult, true)
    }

    /// Adult titles join a search after the main answer; the title typed exactly comes first.
    func testSearchMergesAdultTitlesByMatch() {
        let main = [Show(id: 1, title: "Panty & Stocking with Garterbelt"), Show(id: 2, title: "Overflowing Love"),
                    Show(id: 3, title: "Binbougami ga!")]
        let adult = [Show(id: 113417, title: "Overflow", romaji: "Overflow", isAdult: true), Show(id: 2, title: "Overflowing Love")]
        XCTAssertEqual(ShowCatalog.merged(main: main, adult: adult, query: " overflow").map(\.id), [113417, 2, 1, 3])
        XCTAssertEqual(ShowCatalog.merged(main: main, adult: [], query: "garterbelt").map(\.id), [1, 2, 3])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
