import XCTest
@testable import CatalogKit

final class ShowExtrasTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private var live: Bool { ProcessInfo.processInfo.environment["CATALOG_LIVE"] == "1" }

    // MARK: ani.zip

    func testAniZipParsing() throws {
        let root = try object("""
        {"episodes": {
          "1": {"episodeNumber": 1, "title": {"ja": "冒険の終わり", "en": "The Journey`s End", "x-jat": "Bouken no Owari"},
                "overview": "  The world celebrates.  ", "image": "https://img/1.jpg", "runtime": 26, "length": 30},
          "2": {"title": {"ja": "オスガキにも穴はあるんだよな", "en": null, "de": "Auch versaute Jungs"},
                "overview": "Ume joins the council.", "image": "https://img/2.jpg", "length": 25},
          "3": {"title": {"en": "Episode 3", "x-jat": "Hito o Korosu Mahou"}, "overview": "TBA", "runtime": 0, "length": 24},
          "4": {"title": {"en": "Episode 4", "ja": "人を殺す魔法"}, "overview": "No overview available.", "image": ""},
          "5": {"title": {"en": null}},
          "S1": {"title": {"en": "Magic Episode 1"}, "overview": "A special.", "image": "https://img/s1.jpg"},
          "0": {"title": {"en": "Zero"}}
        }}
        """)
        let eps = ShowCatalog.aniZipEpisodes(root)
        XCTAssertEqual(Set(eps.keys), [1, 2, 3])
        XCTAssertEqual(eps[1]?.title, "The Journey's End")
        XCTAssertEqual(eps[1]?.overview, "The world celebrates.")
        XCTAssertEqual(eps[1]?.thumbnail?.absoluteString, "https://img/1.jpg")
        XCTAssertEqual(eps[1]?.runtime, 26)
        // No English or romanized name, so no title rather than the Japanese or German one.
        XCTAssertNil(eps[2]?.title)
        XCTAssertEqual(eps[2]?.overview, "Ume joins the council.")
        XCTAssertEqual(eps[2]?.runtime, 25)
        XCTAssertEqual(eps[3]?.title, "Hito o Korosu Mahou")
        XCTAssertNil(eps[3]?.overview)
        XCTAssertNil(eps[3]?.thumbnail)
        XCTAssertEqual(eps[3]?.runtime, 24)
        XCTAssertNil(eps[4])
    }

    func testEpisodeInfoMergeKeepsExistingValues() {
        let eps = [
            ShowEpisode(number: 1, absolute: 1, title: "From AniList", thumbnailURL: URL(string: "https://anilist/1.jpg")),
            ShowEpisode(number: 2, absolute: 2),
            ShowEpisode(number: 3, absolute: 3),
        ]
        let info: [Int: ShowCatalog.EpisodeInfo] = [
            1: .init(title: "From ani.zip", overview: "Synopsis", thumbnail: URL(string: "https://anizip/1.jpg"), runtime: 24),
            2: .init(title: "Second", overview: nil, thumbnail: URL(string: "https://anizip/2.jpg"), runtime: nil),
        ]
        let merged = ShowCatalog.merged(eps, with: info)
        XCTAssertEqual(merged[0].title, "From AniList")
        XCTAssertEqual(merged[0].thumbnailURL?.absoluteString, "https://anilist/1.jpg")
        XCTAssertEqual(merged[0].overview, "Synopsis")
        XCTAssertEqual(merged[0].runtime, 24)
        XCTAssertEqual(merged[1].title, "Second")
        XCTAssertEqual(merged[1].thumbnailURL?.absoluteString, "https://anizip/2.jpg")
        XCTAssertNil(merged[1].overview)
        XCTAssertEqual(merged[2], eps[2])

        let kitsu = ShowCatalog.merged(merged, with: [2: .init(title: "Kitsu", overview: nil, thumbnail: nil, runtime: nil),
                                                      3: .init(title: "Third", overview: nil, thumbnail: nil, runtime: nil)])
        XCTAssertEqual(kitsu[1].title, "Second")
        XCTAssertEqual(kitsu[2].title, "Third")
    }

    func testEpisodeDecodesWithoutNewFields() throws {
        let old = #"{"number": 3, "absolute": 15, "title": "Old", "isAired": true}"#
        let e = try JSONDecoder().decode(ShowEpisode.self, from: Data(old.utf8))
        XCTAssertEqual(e.title, "Old")
        XCTAssertNil(e.overview)
        XCTAssertNil(e.runtime)
        let round = try JSONDecoder().decode(ShowEpisode.self, from: JSONEncoder().encode(
            ShowEpisode(number: 1, absolute: 1, overview: "Text", runtime: 24)))
        XCTAssertEqual(round.overview, "Text")
        XCTAssertEqual(round.runtime, 24)
    }

    // MARK: AniSkip

    func testAniSkipParsing() throws {
        let root = try object("""
        {"found": true, "results": [
          {"interval": {"startTime": 1378.647, "endTime": 1470}, "skipType": "ed", "episodeLength": 1470.1013},
          {"interval": {"startTime": 43.87, "endTime": 133.87}, "skipType": "op", "episodeLength": 1469.9},
          {"interval": {"startTime": 58.713, "endTime": 148.713}, "skipType": "mixed-op", "episodeLength": 1470},
          {"interval": {"startTime": 0, "endTime": 30}, "skipType": "recap", "episodeLength": 1470},
          {"interval": {"startTime": 200, "endTime": 260}, "skipType": "unknown", "episodeLength": 1470}
        ], "message": "Successfully found skip times", "statusCode": 200}
        """)
        let s = ShowCatalog.skipSegments(root, duration: 1465)
        XCTAssertEqual(s.map(\.kind), [.recap, .intro, .credits])
        // The overlapping intros were timed against slightly different cuts; the closer one wins.
        XCTAssertEqual(s[1], SkipSegment(kind: .intro, start: 43.87, end: 133.87))
        XCTAssertEqual(s[2].end, 1465)

        let mixed = try object(#"{"found": true, "results": [{"interval": {"startTime": 1300, "endTime": 1390}, "skipType": "mixed-ed", "episodeLength": 0}]}"#)
        XCTAssertEqual(ShowCatalog.skipSegments(mixed, duration: 0), [SkipSegment(kind: .credits, start: 1300, end: 1390)])

        let missing = try object(#"{"found": false, "results": [], "message": "No skip times found", "statusCode": 404}"#)
        XCTAssertEqual(ShowCatalog.skipSegments(missing, duration: 1440), [])
    }

    // MARK: Chapters

    func testChapterSkipNames() {
        for name in ["Opening", "OP", "op1", "OP 2", "Intro", "Opening Song", "Opening Credits"] {
            XCTAssertEqual(ChapterSkips.kind(name), .intro, name)
        }
        for name in ["Ending", "ED", "ED1", "Credits", "Ending Song", "end credits"] {
            XCTAssertEqual(ChapterSkips.kind(name), .credits, name)
        }
        for name in ["Preview", "Next Episode", "Next Ep.", "Yokoku", "Next Episode Preview"] {
            XCTAssertEqual(ChapterSkips.kind(name), .preview, name)
        }
        for name in ["Recap", "Previously on"] {
            XCTAssertEqual(ChapterSkips.kind(name), .recap, name)
        }
        for name in ["Prologue", "Avant", "Part A", "Part B", "Episode", "Chapter 1", "Chapter 01", "Introduction",
                     "Stop", "Edward", "Opera", "Topics", "Eyecatch"] {
            XCTAssertNil(ChapterSkips.kind(name), name)
        }
    }

    func testChapterSkipSegments() {
        let chapters: [(name: String, start: Double, end: Double?)] = [
            ("Part A", 90, nil),
            ("Opening", 0, nil),
            ("Ending", 1300, 1390),
            ("Preview", 1390, nil),
        ]
        XCTAssertEqual(ChapterSkips.segments(chapters, duration: 1420), [
            SkipSegment(kind: .intro, start: 0, end: 90),
            SkipSegment(kind: .credits, start: 1300, end: 1390),
            SkipSegment(kind: .preview, start: 1390, end: 1420),
        ])

        let limits: [(name: String, start: Double, end: Double?)] = [
            ("OP", 0, 5),
            ("Intro", 5, 400),
            ("ED", 1200, nil),
            ("Next Episode", 1380, nil),
        ]
        // Too short, too long, an ending of 3 minutes, and a preview over 2 minutes.
        XCTAssertEqual(ChapterSkips.segments(limits, duration: 1530), [SkipSegment(kind: .credits, start: 1200, end: 1380)])
        XCTAssertEqual(ChapterSkips.segments([("Recap", 0, 0)], duration: 60), [SkipSegment(kind: .recap, start: 0, end: 60)])
    }

    // MARK: Schedule and recommendations

    func testScheduleParsing() throws {
        let data = try object("""
        {"p1": {"airingSchedules": [
          {"episode": 9, "airingAt": 1795161600, "media": {"id": 210482, "idMal": 61469, "format": "ONA", "isAdult": false,
                                                           "title": {"romaji": "JoJo no Kimyou na Bouken", "english": "JoJo's Bizarre Adventure"}}},
          {"episode": 3, "airingAt": 1795165200, "media": {"id": 1, "format": "TV", "isAdult": true, "title": {"romaji": "Adult"}}},
          {"episode": 1, "airingAt": 1795165200, "media": {"id": 2, "format": "MUSIC", "isAdult": false, "title": {"romaji": "Song"}}},
          {"episode": 2, "airingAt": 1795165200, "media": null}
        ]},
        "p2": {"airingSchedules": [
          {"episode": 5, "airingAt": 1795170000, "media": {"id": 3, "format": "TV_SHORT", "isAdult": false, "title": {"romaji": "Short"}}}
        ]},
        "p3": {"airingSchedules": []}}
        """)
        let eps = ShowCatalog.airingEpisodes(data)
        XCTAssertEqual(eps.map(\.id), ["210482.9", "3.5"])
        XCTAssertEqual(eps[0].show.title, "JoJo's Bizarre Adventure")
        XCTAssertEqual(eps[0].show.malID, 61469)
        XCTAssertEqual(eps[0].airingAt, Date(timeIntervalSince1970: 1_795_161_600))
        XCTAssertTrue(ShowCatalog.scheduleQuery.contains("p6: Page(page: 6, perPage: 50)"))
    }

    func testRecommendationsParsing() throws {
        let data = try object("""
        {"m": {"recommendations": {"nodes": [
          {"mediaRecommendation": {"id": 21827, "format": "TV", "isAdult": false, "title": {"romaji": "Violet Evergarden", "english": "Violet Evergarden"}}},
          {"mediaRecommendation": null},
          {"mediaRecommendation": {"id": 9, "isAdult": true, "title": {"romaji": "Adult"}}},
          {"mediaRecommendation": {"id": 21827, "format": "TV", "isAdult": false, "title": {"romaji": "Violet Evergarden"}}},
          {"mediaRecommendation": {"id": 154587, "format": "TV", "isAdult": false, "title": {"romaji": "Sousou no Frieren"}}},
          {"mediaRecommendation": {"id": 153518, "format": "TV", "isAdult": false, "title": {"romaji": "Dungeon Meshi", "english": "Delicious in Dungeon"}}}
        ]}}}
        """)
        let shows = ShowCatalog.recommendations(data, excluding: 154587)
        XCTAssertEqual(shows.map(\.id), [21827, 153518])
        XCTAssertEqual(shows.last?.title, "Delicious in Dungeon")

        let nodes: [[String: Any]] = (1...15).map { ["mediaRecommendation": ["id": $0, "title": ["romaji": "S\($0)"]] as [String: Any]] }
        let many: [String: Any] = ["m": ["recommendations": ["nodes": nodes]]]
        XCTAssertEqual(ShowCatalog.recommendations(many, excluding: 0).count, 12)
    }

    // MARK: Live

    /// Hits ani.zip, Kitsu and AniList. Run with CATALOG_LIVE=1.
    func testLiveEpisodeInfo() async throws {
        try XCTSkipUnless(live)
        let catalog = ShowCatalog()
        let root = try await catalog.json(URL(string: "https://api.ani.zip/mappings?anilist_id=191656")!, accept: "application/json")
        let eps = ShowCatalog.aniZipEpisodes(root)
        XCTAssertNotNil(eps[1]?.overview)
        XCTAssertNotNil(eps[1]?.thumbnail)
        XCTAssertNotNil(eps[1]?.runtime)
        print("ani.zip 191656:", eps.keys.sorted().map { "\($0): \(eps[$0]?.title ?? "-") overview=\(eps[$0]?.overview != nil) image=\(eps[$0]?.thumbnail != nil)" })

        let details = try await catalog.details(id: 191656)
        let full = await catalog.withEpisodeInfo(details)
        let first = try XCTUnwrap(full.seasons.first?.episodes.first)
        XCTAssertNotNil(first.overview)
        XCTAssertNotNil(first.thumbnailURL)
        print("191656 E1:", first.title ?? "-", first.runtime ?? 0, first.overview?.prefix(60) ?? "-")
    }

    /// Hits AniSkip. Run with CATALOG_LIVE=1.
    func testLiveSkipSegments() async throws {
        try XCTSkipUnless(live)
        let catalog = ShowCatalog()
        let frieren = try await catalog.skipSegments(malID: 52991, episode: 1, duration: 1440)
        print("Frieren E1:", frieren)
        XCTAssertTrue(frieren.contains { $0.kind == .intro })
        let onePiece = try await catalog.skipSegments(malID: 21, episode: 1000, duration: 0)
        print("One Piece E1000:", onePiece)
        XCTAssertFalse(onePiece.isEmpty)
        let none = try await catalog.skipSegments(malID: 52991, episode: 500, duration: 1440)
        XCTAssertEqual(none, [])
    }

    /// Hits AniList. Run with CATALOG_LIVE=1.
    func testLiveScheduleAndRecommendations() async throws {
        try XCTSkipUnless(live)
        let catalog = ShowCatalog()
        let now = Date()
        let week = try await catalog.schedule(from: now, to: now.addingTimeInterval(7 * 86400))
        print("airing this week:", week.count, week.prefix(5).map { "\($0.show.title) #\($0.episode) \($0.airingAt)" })
        XCTAssertGreaterThan(week.count, 20)
        XCTAssertTrue(week.allSatisfy { $0.airingAt >= now && $0.airingAt < now.addingTimeInterval(7 * 86400) })
        XCTAssertEqual(week.map(\.airingAt), week.map(\.airingAt).sorted())
        XCTAssertEqual(Set(week.map(\.id)).count, week.count)

        let recs = try await catalog.recommendations(id: 154587)
        print("More like Frieren:", recs.map(\.title))
        XCTAssertFalse(recs.isEmpty)
        XCTAssertLessThanOrEqual(recs.count, 12)
        XCTAssertFalse(recs.contains { $0.id == 154587 })
    }
}
