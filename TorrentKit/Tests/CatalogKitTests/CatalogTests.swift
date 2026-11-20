import XCTest
@testable import CatalogKit

final class CatalogTests: XCTestCase {
    func testQueryKeySharedAcrossGroups() {
        let a = CatalogQuery(release: ReleaseName.parse("[SubsPlease] Sousou no Frieren - 05 (1080p) [F02B9CA3].mkv"))
        let b = CatalogQuery(release: ReleaseName.parse("[Erai-raws] Sousou no Frieren - 06 [720p].mkv"))
        XCTAssertEqual(a.key, b.key)
        XCTAssertTrue(a.prefersAnime)
        XCTAssertTrue(a.isEpisodic)
    }

    func testBestAnimeRejectsUnrelatedHits() {
        let q = CatalogQuery(release: ReleaseName.parse("[Group] Sousou no Frieren - 01"))
        let media: [[String: Any]] = [
            ["title": ["romaji": "Spy x Family", "english": "SPY x FAMILY"], "format": "TV"],
            ["title": ["romaji": "Sousou no Frieren", "english": "Frieren: Beyond Journey’s End"], "format": "TV",
             "episodes": 28, "seasonYear": 2023, "genres": ["Adventure"],
             "description": "The adventure is over.<br><br>(Source: Crunchyroll)",
             "coverImage": ["extraLarge": "https://img/x.jpg"], "bannerImage": "https://img/b.jpg"],
        ]
        let e = CatalogClient.bestAnime(media, for: q)
        XCTAssertEqual(e?.title, "Frieren: Beyond Journey’s End")
        XCTAssertEqual(e?.episodeCount, 28)
        XCTAssertEqual(e?.overview, "The adventure is over.")
        XCTAssertEqual(e?.backdropURL?.absoluteString, "https://img/b.jpg")
        XCTAssertNil(CatalogClient.bestAnime(Array(media.prefix(1)), for: q))
    }

    func testPlainText() {
        XCTAssertEqual(CatalogClient.plainText("<p>Tom &amp; Jerry&#039;s <b>show</b>.</p>"), "Tom & Jerry's show.")
    }

    /// Hits the real services. Run with CATALOG_LIVE=1.
    func testLiveLookups() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CATALOG_LIVE"] == "1")
        let client = CatalogClient()
        let anime = [
            CatalogQuery(release: ReleaseName.parse("[SubsPlease] Sousou no Frieren - 05 (1080p) [F02B9CA3].mkv")),
            CatalogQuery(release: ReleaseName.parse("[Judas] Shingeki no Kyojin (Attack on Titan) (Season 1) [BD 1080p] (Batch)")),
            CatalogQuery(release: ReleaseName.parse("[Group] Zzqxj Nonexistent Show - 01")),
        ]
        let res = try await client.lookupAnime(anime)
        for q in anime { print("anime", q.key, "→", res[q.key].map { $0?.title ?? "nil" } ?? "unchecked", res[q.key]??.posterURL?.absoluteString ?? "") }
        XCTAssertNotNil(res[anime[0].key] ?? nil)
        XCTAssertNotNil(res[anime[1].key] ?? nil)
        XCTAssertNil(res[anime[2].key] ?? nil)

        let show = try await client.lookupLiveAction(CatalogQuery(release: ReleaseName.parse("The.Bear.S02.1080p.WEB.h264-GROUP")))
        print("show", show?.title ?? "nil", show?.posterURL?.absoluteString ?? "", show?.backdropURL?.absoluteString ?? "")
        XCTAssertEqual(show?.title, "The Bear")

        let movie = try await client.lookupLiveAction(CatalogQuery(release: ReleaseName.parse("Oppenheimer.2023.2160p.UHD.BluRay.x265-GROUP")))
        print("movie", movie?.title ?? "nil", movie?.year ?? 0, movie?.posterURL?.absoluteString ?? "")
        XCTAssertEqual(movie?.year, 2023)
    }
}
