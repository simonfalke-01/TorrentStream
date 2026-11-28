import XCTest
@testable import CatalogKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RatingsTests: XCTestCase {
    // MARK: MyAnimeList ratings

    func testMALRatingMapping() {
        let cases: [(String, ContentRating?, String?)] = [
            ("G - All Ages", .allAges, "G"),
            ("PG - Children", .children, "PG"),
            ("PG-13 - Teens 13 or older", .teens, "PG-13"),
            ("R - 17+ (violence & profanity)", .older17, "R"),
            ("R+ - Mild Nudity", .mildNudity, "R+"),
            ("Rx - Hentai", .adult, "18+"),
            ("None", nil, nil),
            ("", nil, nil),
            ("TV-14", nil, nil),
        ]
        for (raw, rating, badge) in cases {
            XCTAssertEqual(ContentRating(mal: raw), rating, raw)
            XCTAssertEqual(ContentRating(mal: raw)?.badge, badge, raw)
        }
        XCTAssertEqual(ContentRating.teens.spokenLabel, "Rated PG-13")
        XCTAssertEqual(ContentRating.adult.spokenLabel, "Adults only")
        // Nothing shown in the interface spells out MyAnimeList's "Hentai" or "Rx".
        for r in ContentRating.allCases {
            XCTAssertFalse(r.badge.contains("Rx"))
            XCTAssertFalse(r.summary.localizedCaseInsensitiveContains("hentai"))
        }
    }

    func testJikanParsing() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"data": {"mal_id": 52991, "rating": "PG-13 - Teens 13 or older", "title": "Sousou no Frieren"}}
        """.utf8)) as? [String: Any])
        XCTAssertEqual(ShowCatalog.malRating(root), .teens)
        XCTAssertNil(ShowCatalog.malRating(["data": ["rating": NSNull()]]))
        XCTAssertNil(ShowCatalog.malRating([:]))
    }

    func testKitsuRatingParsing() {
        func root(_ rating: String?, _ guide: String?) -> [String: Any] {
            var a: [String: Any] = [:]
            a["ageRating"] = rating
            a["ageRatingGuide"] = guide
            return ["data": [["type": "mappings"]], "included": [["type": "anime", "id": "1", "attributes": a]]]
        }
        XCTAssertEqual(ShowCatalog.kitsuRating(root("G", "All Ages")), .allAges)
        XCTAssertEqual(ShowCatalog.kitsuRating(root("PG", "Children")), .children)
        XCTAssertEqual(ShowCatalog.kitsuRating(root("PG", "Teens 13 or Older")), .teens)
        XCTAssertNil(ShowCatalog.kitsuRating(root("PG", nil)))
        XCTAssertEqual(ShowCatalog.kitsuRating(root("R", "17+ (violence & profanity)")), .older17)
        XCTAssertEqual(ShowCatalog.kitsuRating(root("R", "Violence, Profanity")), .older17)
        XCTAssertEqual(ShowCatalog.kitsuRating(root("R", "Mild Nudity")), .mildNudity)
        XCTAssertEqual(ShowCatalog.kitsuRating(root("R18", nil)), .adult)
        XCTAssertNil(ShowCatalog.kitsuRating(root(nil, nil)))
        XCTAssertNil(ShowCatalog.kitsuRating(["data": []]))
    }

    func testAdultFlagDecidesShownRating() {
        XCTAssertEqual(ContentRating.shown(mal: nil, isAdult: true), .adult)
        XCTAssertEqual(ContentRating.shown(mal: .mildNudity, isAdult: true), .adult)
        XCTAssertEqual(ContentRating.shown(mal: .teens, isAdult: false), .teens)
        XCTAssertEqual(ContentRating.shown(mal: .teens, isAdult: nil), .teens)
        XCTAssertNil(ContentRating.shown(mal: nil, isAdult: false))
        XCTAssertNil(ContentRating.shown(mal: nil, isAdult: nil))
    }

    // MARK: Jikan request budget

    func testJikanBudgetSpacesAndCapsRequests() throws {
        let budget = JikanBudget()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(try budget.reserve(now: t0), 0, accuracy: 0.001)
        XCTAssertEqual(try budget.reserve(now: t0), JikanBudget.spacing, accuracy: 0.001)
        XCTAssertEqual(try budget.reserve(now: t0), 2 * JikanBudget.spacing, accuracy: 0.001)
        // Booked further out than a request should wait: fails at once rather than holding the page's work.
        var booked = 3
        while (try? budget.reserve(now: t0)) != nil { booked += 1 }
        let fit = Int(JikanBudget.maxWait / JikanBudget.spacing)
        XCTAssertTrue((fit...fit + 1).contains(booked), "\(booked)")

        // A minute's worth of requests, spaced out, then the next one waits for the oldest to age out.
        let capped = JikanBudget()
        var now = t0
        for _ in 0..<JikanBudget.perMinute {
            XCTAssertEqual(try capped.reserve(now: now), 0, accuracy: 0.001)
            now.addTimeInterval(1)
        }
        XCTAssertThrowsError(try capped.reserve(now: now))
        XCTAssertEqual(try capped.reserve(now: t0.addingTimeInterval(60)), 0, accuracy: 0.001)
    }

    func testJikanBudgetBacksOffAfter429() throws {
        let budget = JikanBudget()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let url = URL(string: "https://api.jikan.moe/v4/anime/1")!
        budget.finished(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil), now: t0)
        XCTAssertNoThrow(try budget.reserve(now: t0))
        budget.finished(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "10"]), now: t0)
        XCTAssertThrowsError(try budget.reserve(now: t0.addingTimeInterval(9)))
        XCTAssertNoThrow(try budget.reserve(now: t0.addingTimeInterval(10)))
        // Without Retry-After it holds off a minute.
        budget.finished(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil), now: t0.addingTimeInterval(20))
        XCTAssertThrowsError(try budget.reserve(now: t0.addingTimeInterval(79)))
        XCTAssertNoThrow(try budget.reserve(now: t0.addingTimeInterval(80)))
        // A Jikan that can't be reached is left alone for a while.
        budget.unreachable(now: t0.addingTimeInterval(100))
        XCTAssertThrowsError(try budget.reserve(now: t0.addingTimeInterval(200)))
        XCTAssertNoThrow(try budget.reserve(now: t0.addingTimeInterval(220)))
    }

    // MARK: AniList tags

    func testTagParsingMarksSpoilers() {
        let m: [String: Any] = [
            "id": 1, "title": ["romaji": "Sousou no Frieren"], "genres": ["Adventure"],
            "tags": [
                ["name": "Elf", "rank": 95, "isAdult": false, "isGeneralSpoiler": false, "isMediaSpoiler": false],
                ["name": "Time Skip", "rank": 80, "isAdult": false, "isGeneralSpoiler": false, "isMediaSpoiler": true],
                ["name": "Tragedy", "rank": 70, "isAdult": false, "isGeneralSpoiler": true, "isMediaSpoiler": false],
                ["name": "  ", "rank": 99],
            ],
        ]
        let s = ShowCatalog.show(m)
        XCTAssertEqual(s?.tags?.map(\.name), ["Elf", "Time Skip", "Tragedy"])
        XCTAssertEqual(s?.tags?.map(\.isSpoiler), [false, true, true])
        XCTAssertEqual(s?.listedTags.map(\.name), ["Elf"])
        // Lists don't ask for tags: unknown rather than none.
        XCTAssertNil(ShowCatalog.show(["id": 2, "title": ["romaji": "X"]])?.tags)
    }

    func testListedTagsFilterAndSort() {
        let tags = [
            ShowTag(name: "Magic", rank: 72),
            ShowTag(name: "Female Protagonist", rank: 94),
            ShowTag(name: "Death of a Major Character", rank: 90, isSpoiler: true),
            ShowTag(name: "Nudity", rank: 88, isAdult: true),
            ShowTag(name: "Travel", rank: 72),
            ShowTag(name: "Iyashikei", rank: 40),
            ShowTag(name: "magic", rank: 60),
            ShowTag(name: "Elf", rank: 100),
        ]
        XCTAssertEqual(ShowTag.listed(tags, adultShow: false).map(\.name), ["Elf", "Female Protagonist", "Magic", "Travel"])
        XCTAssertEqual(ShowTag.listed(tags, adultShow: true).map(\.name), ["Elf", "Female Protagonist", "Nudity", "Magic", "Travel"])
        XCTAssertEqual(ShowTag.listed(tags, adultShow: false, limit: 2).map(\.name), ["Elf", "Female Protagonist"])
        let many = (0..<20).map { ShowTag(name: "Tag \($0)", rank: 100 - $0) }
        XCTAssertEqual(ShowTag.listed(many, adultShow: false).count, ShowTag.listLimit)

        var show = Show(id: 1, title: "X", isAdult: nil, tags: tags)
        XCTAssertFalse(show.listedTags.contains { $0.isAdult })
        show.isAdult = true
        XCTAssertTrue(show.listedTags.contains { $0.name == "Nudity" })
    }

    func testShowsSavedBeforeTagsStillDecode() throws {
        let old = """
        {"id": 1, "title": "Frieren", "synonyms": [], "genres": ["Drama"], "isAdult": false}
        """
        let show = try JSONDecoder().decode(Show.self, from: Data(old.utf8))
        XCTAssertNil(show.tags)
        XCTAssertEqual(show.listedTags, [])
        let tagged = Show(id: 1, title: "Frieren", tags: [ShowTag(name: "Elf", rank: 95)])
        XCTAssertEqual(try JSONDecoder().decode(Show.self, from: JSONEncoder().encode(tagged)), tagged)
    }

    /// Hits AniList and Jikan. Run with CATALOG_LIVE=1.
    func testLiveTagsAndRating() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CATALOG_LIVE"] == "1")
        let catalog = ShowCatalog()
        // A long franchise, so the season query carries tags for many entries at once.
        let aot = try await catalog.details(id: 20958)
        XCTAssertFalse(aot.show.listedTags.isEmpty)
        XCTAssertTrue(aot.seasons.allSatisfy { $0.media.tags != nil })
        print("AoT tags:", aot.show.listedTags.map { "\($0.name) \($0.rank)" })
        let frieren = try await catalog.details(id: 154587)
        print("Frieren tags:", frieren.show.listedTags.map(\.name))
        let mal = try XCTUnwrap(frieren.show.malID)
        let rating = try await catalog.contentRating(malID: mal, anilistID: frieren.show.id)
        XCTAssertEqual(rating, .teens)
        // Kitsu on its own, as when Jikan can't be reached.
        let kitsu = try await catalog.contentRating(malID: nil, anilistID: frieren.show.id)
        XCTAssertEqual(kitsu, .teens)
    }
}
