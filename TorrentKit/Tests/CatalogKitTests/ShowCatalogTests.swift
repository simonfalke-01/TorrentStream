import XCTest
@testable import CatalogKit

final class ShowCatalogTests: XCTestCase {
    func testStreamingEpisodesShiftAbsoluteNumbers() {
        let list: [[String: Any]] = [
            ["title": "Episode 29 - The Journey Continues", "thumbnail": "https://img/29.jpg"],
            ["title": "Episode 30 - Another Day"],
            ["title": "Episode 31"],
        ]
        let eps = ShowCatalog.streamingEpisodes(list, count: 10)
        XCTAssertEqual(eps[1]?.title, "The Journey Continues")
        XCTAssertEqual(eps[1]?.thumbnail?.absoluteString, "https://img/29.jpg")
        XCTAssertEqual(eps[2]?.title, "Another Day")
        XCTAssertNotNil(eps[3])
        XCTAssertNil(eps[3]?.title)

        let plain = ShowCatalog.streamingEpisodes([["title": "Episode 5 - Phantoms of the Dead"]], count: 28)
        XCTAssertEqual(plain[5]?.title, "Phantoms of the Dead")
    }

    func testShowParsing() {
        let m: [String: Any] = [
            "id": 1, "idMal": 2, "format": "TV", "status": "RELEASING", "episodes": 12,
            "title": ["romaji": "Sousou no Frieren", "english": "Frieren"],
            "synonyms": ["葬送のフリーレン", "Frieren at the Funeral"],
            "nextAiringEpisode": ["episode": 6, "airingAt": 1_800_000_000],
            "genres": ["Drama"],
        ]
        let s = ShowCatalog.show(m)
        XCTAssertEqual(s?.title, "Frieren")
        XCTAssertEqual(s?.synonyms, ["Frieren at the Funeral"])
        XCTAssertEqual(s?.airedEpisodes, 5)
        XCTAssertEqual(s?.names.first, "Sousou no Frieren")
        XCTAssertNil(ShowCatalog.show(["id": 3, "isAdult": true, "title": ["romaji": "X"]]))
    }

    func testKitsuSearchParsing() {
        let root: [String: Any] = [
            "data": [
                ["id": "1", "attributes": ["subtype": "TV", "status": "finished", "canonicalTitle": "Sousou no Frieren",
                                          "titles": ["en": "Frieren: Beyond Journey’s End", "en_jp": "Sousou no Frieren"],
                                          "abbreviatedTitles": ["Frieren at the Funeral"], "episodeCount": 28,
                                          "startDate": "2023-09-29", "averageRating": "88.88",
                                          "posterImage": ["large": "https://media.kitsu.app/p.jpg"]],
                 "relationships": ["mappings": ["data": [["type": "mappings", "id": "10"], ["type": "mappings", "id": "11"]]]]],
                // Music videos and entries AniList doesn't know are left out.
                ["id": "2", "attributes": ["subtype": "music", "canonicalTitle": "Haru"],
                 "relationships": ["mappings": ["data": [["type": "mappings", "id": "12"]]]]],
                ["id": "3", "attributes": ["subtype": "TV", "canonicalTitle": "Unmapped"],
                 "relationships": ["mappings": ["data": []]]],
            ],
            "included": [
                ["type": "mappings", "id": "10", "attributes": ["externalSite": "anilist/anime", "externalId": "154587"]],
                ["type": "mappings", "id": "11", "attributes": ["externalSite": "myanimelist/anime", "externalId": "52991"]],
                ["type": "mappings", "id": "12", "attributes": ["externalSite": "anilist/anime", "externalId": "175691"]],
            ],
        ]
        let shows = ShowCatalog.kitsuShows(root)
        XCTAssertEqual(shows.map(\.id), [154587])
        XCTAssertEqual(shows.first?.malID, 52991)
        XCTAssertEqual(shows.first?.title, "Frieren: Beyond Journey’s End")
        XCTAssertEqual(shows.first?.romaji, "Sousou no Frieren")
        XCTAssertEqual(shows.first?.format, "TV")
        XCTAssertEqual(shows.first?.status, "FINISHED")
        XCTAssertEqual(shows.first?.year, 2023)
        XCTAssertEqual(shows.first?.score, 89)
        XCTAssertNotNil(shows.first?.posterURL)
    }

    func testCurrentSeason() {
        let d = Date(timeIntervalSince1970: 1_763_600_000) // Nov 2025
        XCTAssertEqual(ShowCatalog.currentSeason(d).0, "FALL")
    }

    /// Hits AniList and Kitsu. Run with CATALOG_LIVE=1.
    func testLiveShows() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CATALOG_LIVE"] == "1")
        let catalog = ShowCatalog()
        let rows = try await catalog.browse()
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { !$0.shows.isEmpty })

        let found = try await catalog.kitsuSearch("Frieren")
        let frieren = try XCTUnwrap(found.first { $0.romaji == "Sousou no Frieren" })
        XCTAssertEqual(frieren.id, 154587)

        // Start from the first season; the sequel should follow.
        let started = Date()
        let details = try await catalog.details(id: frieren.id)
        print("details took", Date().timeIntervalSince(started))
        XCTAssertGreaterThanOrEqual(details.seasons.count, 2)
        XCTAssertEqual(details.seasons[0].media.id, 154587)
        XCTAssertEqual(details.seasons[0].episodes.count, 28)
        XCTAssertNotNil(details.seasons[0].episodes[4].title)
        XCTAssertEqual(details.seasons[1].episodeOffset, 28)
        XCTAssertEqual(details.seasons[1].episodes.first?.absolute, 29)
        let enrichStart = Date()
        let full = await catalog.withEpisodeInfo(details)
        print("episode info took", Date().timeIntervalSince(enrichStart))
        XCTAssertNotNil(full.seasons[1].episodes.first?.title)
        XCTAssertNotNil(full.seasons[0].episodes.last?.thumbnailURL)
        print("Frieren seasons:", full.seasons.map { "\($0.number): \($0.media.title) \($0.episodes.count) eps" })
        print("S1E5:", full.seasons[0].episodes[4].title ?? "-", "S2E1:", full.seasons[1].episodes.first?.title ?? "-")

        // Starting from a later season walks back to the first.
        let fromSequel = try await catalog.details(id: details.seasons[1].media.id)
        XCTAssertEqual(fromSequel.show.id, 154587)

        let movie = try await catalog.search("Your Name")
        let kimi = try XCTUnwrap(movie.first { $0.isMovie })
        let movieDetails = try await catalog.details(id: kimi.id)
        XCTAssertEqual(movieDetails.seasons.count, 1)
        XCTAssertEqual(movieDetails.seasons[0].episodes.count, 1)

        // A long show: every TV season in order, starting from the middle.
        let aotStart = Date()
        let aot = try await catalog.details(id: 20958) // Attack on Titan Season 2
        print("AoT details took", Date().timeIntervalSince(aotStart), aot.seasons.map(\.media.title))
        XCTAssertEqual(aot.show.id, 16498)
        XCTAssertGreaterThanOrEqual(aot.seasons.count, 4)

        let fallback = try await catalog.anilistSearch("Frieren")
        XCTAssertTrue(fallback.contains { $0.id == 154587 })
    }
}
