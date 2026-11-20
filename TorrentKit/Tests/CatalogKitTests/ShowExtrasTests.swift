import XCTest
@testable import CatalogKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        XCTAssertEqual(Set(eps.keys), [1, 2, 3, 4])
        XCTAssertEqual(eps[1]?.title, "The Journey's End")
        XCTAssertEqual(eps[1]?.overview, "The world celebrates.")
        XCTAssertEqual(eps[1]?.thumbnail?.absoluteString, "https://img/1.jpg")
        XCTAssertEqual(eps[1]?.runtime, 26)
        // No English or romanized name, so the Japanese one rather than the German one.
        XCTAssertEqual(eps[2]?.title, "オスガキにも穴はあるんだよな")
        XCTAssertEqual(eps[2]?.overview, "Ume joins the council.")
        XCTAssertEqual(eps[2]?.runtime, 25)
        XCTAssertEqual(eps[3]?.title, "Hito o Korosu Mahou")
        XCTAssertNil(eps[3]?.overview)
        XCTAssertNil(eps[3]?.thumbnail)
        XCTAssertEqual(eps[3]?.runtime, 24)
        XCTAssertEqual(eps[4], ShowCatalog.EpisodeInfo(title: "人を殺す魔法"))
        XCTAssertNil(eps[5])
    }

    func testAniZipTitlePreference() throws {
        let root = try object("""
        {"episodes": {
          "1": {"title": {"ja": "冒険の終わり", "x-jat": "Bouken no Owari", "en": "The Journey's End"}},
          "2": {"title": {"ja": "別に魔法じゃなくたって", "x-jat": "Betsu ni Mahou ja Nakutatte", "en": null}},
          "3": {"title": {"ja": "人を殺す魔法", "en": "Episode 3"}},
          "4": {"title": {"ja": "第4話", "en": ""}},
          "5": {"title": {"ja": "  ", "x-jat": "冒険", "en": "エピソード"}}
        }}
        """)
        let eps = ShowCatalog.aniZipEpisodes(root)
        XCTAssertEqual(eps[1]?.title, "The Journey's End")
        XCTAssertEqual(eps[2]?.title, "Betsu ni Mahou ja Nakutatte")
        XCTAssertEqual(eps[3]?.title, "人を殺す魔法")
        XCTAssertNil(eps[4])
        // Japanese script only counts from the Japanese field.
        XCTAssertNil(eps[5])
    }

    func testKitsuTitlePreference() {
        func title(_ a: [String: Any]) -> String? { ShowCatalog.kitsuEpisode(a).title }
        XCTAssertEqual(title(["canonicalTitle": "Bouken no Owari", "titles": ["en": "The Journey's End", "en_jp": "Bouken no Owari", "ja_jp": "冒険の終わり"]]),
                       "The Journey's End")
        XCTAssertEqual(title(["canonicalTitle": "Episode 2", "titles": ["en_jp": "Betsu ni Mahou ja Nakutatte", "ja_jp": "別に魔法じゃなくたって"]]),
                       "Betsu ni Mahou ja Nakutatte")
        XCTAssertEqual(title(["canonicalTitle": "Episode 3", "titles": ["ja_jp": "人を殺す魔法"]]), "人を殺す魔法")
        XCTAssertEqual(title(["canonicalTitle": "人を殺す魔法", "titles": [String: Any]()]), "人を殺す魔法")
        XCTAssertNil(title(["canonicalTitle": "Episode 4", "titles": ["en": "", "ja_jp": ""]]))
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

        let preview = try object(#"{"found": true, "results": [{"interval": {"startTime": 1410, "endTime": 1440}, "skipType": "preview", "episodeLength": 1440}]}"#)
        XCTAssertEqual(ShowCatalog.skipSegments(preview, duration: 1440).map(\.kind), [.preview])
    }

    func testSkipSegmentDecodesWithoutInferredFlag() throws {
        let old = #"{"kind": "intro", "start": 1.5, "end": 91.5}"#
        XCTAssertEqual(try JSONDecoder().decode(SkipSegment.self, from: Data(old.utf8)), SkipSegment(kind: .intro, start: 1.5, end: 91.5))
        let inferred = SkipSegment(kind: .credits, start: 1300, end: 1390, isInferred: true)
        XCTAssertEqual(try JSONDecoder().decode(SkipSegment.self, from: JSONEncoder().encode(inferred)), inferred)
    }

    // MARK: Skip inference

    private func t(_ kind: SkipSegment.Kind, _ start: Double, _ end: Double, _ length: Double? = 1440) -> SkipTime {
        SkipTime(kind: kind, start: start, end: end, length: length)
    }

    func testInferredCreditsKeepDistanceFromEnd() {
        let one = ShowCatalog.inferredSegments([[t(.intro, 0, 90), t(.credits, 1330, 1420)]], missing: [.credits], duration: 1430)
        XCTAssertEqual(one, [SkipSegment(kind: .credits, start: 1320, end: 1410, isInferred: true)])

        // Two neighbours of different lengths agree once measured from the end; the nearest is used.
        let agree = ShowCatalog.inferredSegments([[t(.credits, 1330, 1420, 1440)], [t(.credits, 1362, 1452, 1470)]],
                                                 missing: [.credits], duration: 1440)
        XCTAssertEqual(agree, [SkipSegment(kind: .credits, start: 1330, end: 1420, isInferred: true)])

        let disagree = ShowCatalog.inferredSegments([[t(.credits, 1330, 1420)], [t(.credits, 1300, 1390)]], missing: [.credits], duration: 1440)
        XCTAssertEqual(disagree, [])

        // A neighbour without a known length can't be measured from the end, and nor can a file of unknown length.
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.credits, 1330, 1420, nil)]], missing: [.credits], duration: 1440), [])
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.credits, 1330, 1420)]], missing: [.credits], duration: 0), [])

        // Of the submissions a neighbour has, the one timed against the closest length is used.
        let closest = ShowCatalog.inferredSegments([[t(.credits, 1400, 1490, 1500), t(.credits, 1340, 1430, 1445)]],
                                                   missing: [.credits], duration: 1440)
        XCTAssertEqual(closest, [SkipSegment(kind: .credits, start: 1335, end: 1425, isInferred: true)])
    }

    func testInferredIntroNeedsAgreementOrAnEarlyStart() {
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.intro, 2, 92)]], missing: [.intro], duration: 1440),
                       [SkipSegment(kind: .intro, start: 2, end: 92, isInferred: true)])
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.intro, 60, 150)]], missing: [.intro], duration: 1440), [])
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.intro, 60, 150)], [], [t(.intro, 63, 153, 1470)]], missing: [.intro], duration: 1440),
                       [SkipSegment(kind: .intro, start: 60, end: 150, isInferred: true)])
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.intro, 60, 150)], [t(.intro, 153, 243)]], missing: [.intro], duration: 1440), [])
        // The largest group that agrees wins over a nearer outlier.
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.intro, 153, 243)], [t(.intro, 1.4, 91.4)], [t(.intro, 2, 92)]],
                                                    missing: [.intro], duration: 1440),
                       [SkipSegment(kind: .intro, start: 1.4, end: 91.4, isInferred: true)])
        // Intros keep their time from the start, so a file of unknown length still gets one.
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.intro, 0, 90, nil)]], missing: [.intro], duration: 0).count, 1)
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.recap, 0, 40)], [t(.recap, 1, 41)]], missing: [.recap], duration: 1440).map(\.kind),
                       [.recap])
    }

    func testInferredSegmentsClampAndSkipKnownKinds() {
        let neighbours = [[t(.intro, 0, 90), t(.credits, 1330, 1420), t(.preview, 1420, 1440)]]
        // Only kinds the episode lacks are filled in.
        XCTAssertEqual(ShowCatalog.inferredSegments(neighbours, missing: [.credits, .recap], duration: 1440).map(\.kind), [.credits])
        // In a much shorter file an early ending would start before 0; it is clamped.
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.credits, 10, 100, 1440)]], missing: [.credits], duration: 1400),
                       [SkipSegment(kind: .credits, start: 0, end: 60, isInferred: true)])
        // Under 5 seconds once clamped.
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.credits, 10, 43, 1440)]], missing: [.credits], duration: 1400), [])
        XCTAssertEqual(ShowCatalog.inferredSegments([[t(.intro, 0, 4)]], missing: [.intro], duration: 1440), [])
        XCTAssertEqual(ShowCatalog.inferredSegments([], missing: [.intro, .credits], duration: 1440), [])
    }

    func testSkipSegmentsAskNeighboursOnlyWhenSomethingIsMissing() async throws {
        let base = "https://api.aniskip.com/v2/skip-times"
        func found(_ results: String) -> String { #"{"found": true, "results": ["# + results + "]}" }
        let op = #"{"interval": {"startTime": 1, "endTime": 91}, "skipType": "op", "episodeLength": 1440}"#
        let ed = #"{"interval": {"startTime": 1330, "endTime": 1420}, "skipType": "ed", "episodeLength": 1440}"#
        StubProtocol.set(responses: [
            "\(base)/1/5": (200, found(op)),
            "\(base)/1/4": (200, found("\(op), \(ed)")),
            "\(base)/1/6": (404, #"{"found": false, "results": []}"#),
            "\(base)/1/3": (200, found(ed)),
            "\(base)/1/7": (200, found("")),
            "\(base)/2/1": (200, found("\(op), \(ed)")),
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let catalog = ShowCatalog(session: URLSession(configuration: config))

        let segments = try await catalog.skipSegments(malID: 1, episode: 5, duration: 1430)
        XCTAssertEqual(segments, [SkipSegment(kind: .intro, start: 1, end: 91),
                                  SkipSegment(kind: .credits, start: 1320, end: 1410, isInferred: true)])
        let first = StubProtocol.takeRequested()
        XCTAssertEqual(first.count, 5)
        XCTAssertTrue(first.contains("\(base)/1/5?episodeLength=1430.000"))
        XCTAssertEqual(Set(first.filter { $0.hasSuffix("episodeLength=0") }),
                       Set([4, 6, 3, 7].map { "\(base)/1/\($0)?episodeLength=0" }))

        // Answers are cached, so asking again sends nothing.
        _ = try await catalog.skipSegments(malID: 1, episode: 5, duration: 1430)
        XCTAssertEqual(StubProtocol.takeRequested(), [])

        // An episode with both an intro and an ending needs no neighbours.
        let complete = try await catalog.skipSegments(malID: 2, episode: 1, duration: 1440)
        XCTAssertEqual(complete.map(\.kind), [.intro, .credits])
        XCTAssertEqual(StubProtocol.takeRequested(), ["\(base)/2/1?episodeLength=1440.000"])
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

    func testMergedSkipsPreferChaptersAndSnapCatalogTimes() {
        let chapters: [(name: String, start: Double, end: Double?)] = [
            ("Prologue", 0, nil),
            ("Opening", 112, nil),
            ("Part A", 202, nil),
            ("Part B", 800, nil),
            ("Ending", 1330, nil),
            ("Preview", 1420, nil),
        ]
        let catalog = [
            // Timed against a release without the cold open: wrong for this file, and the chapter wins.
            SkipSegment(kind: .intro, start: 0, end: 90),
            // A recap the chapters don't name, a second off their boundaries.
            SkipSegment(kind: .recap, start: 1, end: 111),
        ]
        XCTAssertEqual(ChapterSkips.merged(catalog: catalog, chapters: chapters, duration: 1440), [
            SkipSegment(kind: .recap, start: 0, end: 112),
            SkipSegment(kind: .intro, start: 112, end: 202),
            SkipSegment(kind: .credits, start: 1330, end: 1420),
            SkipSegment(kind: .preview, start: 1420, end: 1440),
        ])
    }

    func testMergedSkipsCheckInferredTimesAgainstChapters() {
        let unnamed: [(name: String, start: Double, end: Double?)] = [
            ("Chapter 1", 0, nil), ("Chapter 2", 95, nil), ("Chapter 3", 185, nil), ("Chapter 4", 1310, nil),
        ]
        let lined = SkipSegment(kind: .intro, start: 93, end: 186, isInferred: true)
        let off = SkipSegment(kind: .credits, start: 1250, end: 1340, isInferred: true)
        XCTAssertEqual(ChapterSkips.merged(catalog: [lined, off], chapters: unnamed, duration: 1420),
                       [SkipSegment(kind: .intro, start: 95, end: 185, isInferred: true)])

        // With too few chapters to judge by, catalog times stand as they are.
        XCTAssertEqual(ChapterSkips.merged(catalog: [off], chapters: [], duration: 1420), [off])
        // Submitted for this episode rather than inferred, a time stays even when it lines up with nothing.
        let submitted = SkipSegment(kind: .credits, start: 1250, end: 1340)
        XCTAssertEqual(ChapterSkips.merged(catalog: [submitted], chapters: unnamed, duration: 1420), [submitted])
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

        // Episode 4 has only an opening submitted for this cut; the ending comes from its neighbours.
        let inferred = try await catalog.skipSegments(malID: 52991, episode: 4, duration: 1440)
        print("Frieren E4:", inferred)
        XCTAssertTrue(inferred.contains { $0.kind == .intro && !$0.isInferred })
        XCTAssertTrue(inferred.contains { $0.kind == .credits && $0.isInferred })
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

/// Answers requests from canned bodies keyed by URL without the query, and records each request as the URL with only
/// its episodeLength parameter.
final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [String: (Int, String)] = [:]
    private static var requested: [String] = []

    static func set(responses: [String: (Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        self.responses = responses
        requested = []
    }

    static func takeRequested() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = requested
        requested = []
        return out
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        c.queryItems = c.queryItems?.filter { $0.name == "episodeLength" }
        let recorded = c.url?.absoluteString ?? ""
        c.query = nil
        let key = c.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.requested.append(recorded)
        let (status, body) = Self.responses[key] ?? (404, "{}")
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
