import XCTest
@testable import CatalogKit

final class ReleaseNameTests: XCTestCase {
    func testFansubEpisode() {
        let r = ReleaseName.parse("[SubsPlease] Sousou no Frieren - 05 (1080p) [F02B9CA3].mkv")
        XCTAssertEqual(r.title, "Sousou no Frieren")
        XCTAssertEqual(r.group, "SubsPlease")
        XCTAssertEqual(r.episode, 5)
        XCTAssertEqual(r.resolution, "1080p")
        XCTAssertTrue(r.isAnimeStyle)
        XCTAssertFalse(r.isBatch)
    }

    func testDashInTitleUsesLastEpisodeMarker() {
        let r = ReleaseName.parse("[Erai-raws] Kimetsu no Yaiba - Katanakaji no Sato-hen - 01 [1080p][Multiple Subtitle][ABCD1234].mkv")
        XCTAssertEqual(r.title, "Kimetsu no Yaiba - Katanakaji no Sato-hen")
        XCTAssertEqual(r.episode, 1)
    }

    func testNumericTitle() {
        let r = ReleaseName.parse("[Group] 86 - Eighty Six - 05v2 [720p].mkv")
        XCTAssertEqual(r.title, "86 - Eighty Six")
        XCTAssertEqual(r.episode, 5)
        XCTAssertEqual(r.resolution, "720p")
    }

    func testBatchWithAltTitleAndSeason() {
        let r = ReleaseName.parse("[Judas] Shingeki no Kyojin (Attack on Titan) (Season 1) [BD 1080p][HEVC x265 10bit][Dual-Audio][Eng-Subs] (Batch)")
        XCTAssertEqual(r.title, "Shingeki no Kyojin")
        XCTAssertEqual(r.altTitles, ["Attack on Titan"])
        XCTAssertEqual(r.season, 1)
        XCTAssertTrue(r.isBatch)
        XCTAssertNil(r.episode)
    }

    func testEpisodeRange() {
        let r = ReleaseName.parse("[Group] Dandadan - 01-12 (1080p) [Batch]")
        XCTAssertEqual(r.title, "Dandadan")
        XCTAssertEqual(r.episode, 1)
        XCTAssertEqual(r.lastEpisode, 12)
        XCTAssertTrue(r.isBatch)
    }

    func testSeasonSuffixInTitle() {
        let r = ReleaseName.parse("[SubsPlease] Mushoku Tensei S2 - 05 (1080p) [ABCDEF01].mkv")
        XCTAssertEqual(r.title, "Mushoku Tensei")
        XCTAssertEqual(r.season, 2)
        XCTAssertEqual(r.episode, 5)

        let r2 = ReleaseName.parse("[Group] Oshi no Ko 2nd Season - 03 [1080p]")
        XCTAssertEqual(r2.title, "Oshi no Ko")
        XCTAssertEqual(r2.season, 2)
        XCTAssertEqual(r2.episode, 3)
    }

    func testSceneEpisode() {
        let r = ReleaseName.parse("One.Piece.2023.S01E05.The.Pilot.1080p.NF.WEB-DL.DDP5.1.x264-GROUP.mkv")
        XCTAssertEqual(r.title, "One Piece")
        XCTAssertEqual(r.year, 2023)
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 5)
        XCTAssertEqual(r.episodeTitle, "The Pilot")
        XCTAssertEqual(r.resolution, "1080p")
        XCTAssertFalse(r.isAnimeStyle)
        XCTAssertTrue(r.isEpisodic)
    }

    func testSceneSeasonPack() {
        let r = ReleaseName.parse("The.Bear.S02.1080p.WEB.h264-GROUP")
        XCTAssertEqual(r.title, "The Bear")
        XCTAssertEqual(r.season, 2)
        XCTAssertNil(r.episode)
        XCTAssertTrue(r.isBatch)
    }

    func testSceneMovie() {
        let r = ReleaseName.parse("Oppenheimer.2023.2160p.UHD.BluRay.x265-GROUP")
        XCTAssertEqual(r.title, "Oppenheimer")
        XCTAssertEqual(r.year, 2023)
        XCTAssertEqual(r.resolution, "2160p")
        XCTAssertFalse(r.isEpisodic)

        let r2 = ReleaseName.parse("Blade.Runner.2049.2017.1080p.BluRay.x264")
        XCTAssertEqual(r2.title, "Blade Runner 2049")
        XCTAssertEqual(r2.year, 2017)
    }

    func testMovieWithYearInParentheses() {
        let r = ReleaseName.parse("Spirited Away (2001) [1080p]")
        XCTAssertEqual(r.title, "Spirited Away")
        XCTAssertEqual(r.year, 2001)
        XCTAssertNil(r.episode)
    }

    func testBareEpisodeFiles() {
        XCTAssertEqual(ReleaseName.parse("05.mkv").episode, 5)
        XCTAssertEqual(ReleaseName.parse("05.mkv").title, "")
        XCTAssertEqual(ReleaseName.parse("Episode 12.mp4").episode, 12)
        XCTAssertEqual(ReleaseName.parse("[Group] Show 07 [1080p].mkv").episode, 7)
        XCTAssertEqual(ReleaseName.parse("[Group] Show 07 [1080p].mkv").title, "Show")
        XCTAssertEqual(ReleaseName.parse("第03話.mkv").episode, 3)
    }

    func testPlainNames() {
        XCTAssertEqual(ReleaseName.parse("Big Buck Bunny").title, "Big Buck Bunny")
        XCTAssertNil(ReleaseName.parse("Big Buck Bunny").episode)
        XCTAssertEqual(ReleaseName.parse("NCOP.mkv").title, "NCOP")
    }

    func testSimilarity() {
        XCTAssertEqual(ReleaseName.similarity("Sousou no Frieren", "Sousou no Frieren"), 1)
        XCTAssertGreaterThanOrEqual(ReleaseName.similarity("Kimetsu no Yaiba - Katanakaji no Sato-hen", "Kimetsu no Yaiba: Katanakaji no Sato-hen"), 0.99)
        XCTAssertLessThan(ReleaseName.similarity("Frieren", "Spy x Family"), 0.1)
        XCTAssertEqual(ReleaseName.normalize("Frieren: Beyond Journey’s End"), "frieren beyond journey s end")
    }
}
