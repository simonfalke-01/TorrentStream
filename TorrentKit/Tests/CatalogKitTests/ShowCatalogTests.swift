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

    func testCurrentSeason() {
        let d = Date(timeIntervalSince1970: 1_763_600_000) // Nov 2025
        XCTAssertEqual(ShowCatalog.currentSeason(d).0, "FALL")
    }

    /// Hits AniList and Jikan. Run with CATALOG_LIVE=1.
    func testLiveShows() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CATALOG_LIVE"] == "1")
        let catalog = ShowCatalog()
        let rows = try await catalog.browse()
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { !$0.shows.isEmpty })

        let found = try await catalog.search("Frieren")
        let frieren = try XCTUnwrap(found.first { $0.romaji == "Sousou no Frieren" })

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
    }
}
