import XCTest
import CatalogKit
import NyaaKit
@testable import SourceKit

final class SourceKitTests: XCTestCase {
    static func season(_ show: Show, _ number: Int, offset: Int) -> ShowSeason {
        let eps = (1...(show.episodes ?? 1)).map { ShowEpisode(number: $0, absolute: offset + $0) }
        return ShowSeason(media: show, number: number, episodeOffset: offset, episodes: eps)
    }

    static let frieren: ShowDetails = {
        let s1 = Show(id: 154587, title: "Frieren: Beyond Journey’s End", romaji: "Sousou no Frieren",
                      english: "Frieren: Beyond Journey’s End", synonyms: ["Frieren at the Funeral"], format: "TV",
                      status: "FINISHED", episodes: 28)
        let s2 = Show(id: 182255, title: "Frieren: Beyond Journey’s End Season 2", romaji: "Sousou no Frieren 2nd Season",
                      english: "Frieren: Beyond Journey’s End Season 2", format: "TV", status: "FINISHED", episodes: 10)
        return ShowDetails(show: s1, seasons: [season(s1, 1, offset: 0), season(s2, 2, offset: 28)])
    }()

    static let aot: ShowDetails = {
        let s1 = Show(id: 16498, title: "Attack on Titan", romaji: "Shingeki no Kyojin", english: "Attack on Titan",
                      format: "TV", status: "FINISHED", episodes: 25)
        let s4 = Show(id: 110277, title: "Attack on Titan Final Season", romaji: "Shingeki no Kyojin: The Final Season",
                      english: "Attack on Titan Final Season", format: "TV", status: "FINISHED", episodes: 16)
        return ShowDetails(show: s1, seasons: [season(s1, 1, offset: 0), season(s4, 2, offset: 25)])
    }()

    func match(_ name: String, _ d: ShowDetails, _ s: Int, _ e: Int) -> SourceMatcher.Match? {
        let season = d.seasons[s - 1]
        return SourceMatcher.match(name, details: d, season: season, episode: season.episodes[e - 1])
    }

    func testMatchesSeasonAndEpisode() {
        let f = Self.frieren
        XCTAssertNotNil(match("[SubsPlease] Sousou no Frieren - 05 (1080p) [8E3F8FA5].mkv", f, 1, 5))
        XCTAssertNil(match("[SubsPlease] Sousou no Frieren - 05 (1080p) [8E3F8FA5].mkv", f, 2, 5))
        XCTAssertNil(match("[SubsPlease] Sousou no Frieren - 06 (1080p) [8E3F8FA5].mkv", f, 1, 5))
        XCTAssertNotNil(match("[SubsPlease] Sousou no Frieren S2 - 05 (1080p) [6AAEC79A].mkv", f, 2, 5))
        XCTAssertNil(match("[SubsPlease] Sousou no Frieren S2 - 05 (1080p) [6AAEC79A].mkv", f, 1, 5))
        XCTAssertNotNil(match("[Erai-raws] Sousou no Frieren 2nd Season - 05 [1080p CR WEB-DL AVC AAC][MultiSub][42940134]", f, 2, 5))
        XCTAssertNotNil(match("[Yameii] Frieren: Beyond Journey's End - S02E05 [English Dub] [CR WEB-DL 1080p H264 AAC] [0564F2F3] (Sousou no Frieren Season 2 | S2)", f, 2, 5))
        // Counted from the start of the show.
        XCTAssertNotNil(match("[Group] Sousou no Frieren - 33 [1080p].mkv", f, 2, 5))
        XCTAssertNil(match("[SubsPlease] Spy x Family - 05 (1080p).mkv", f, 1, 5))
    }

    func testMatchesBatches() {
        let f = Self.frieren
        let batch = match("[SubsPlease] Sousou no Frieren (01-28) (1080p) [Batch]", f, 1, 5)
        XCTAssertEqual(batch?.isBatch, true)
        XCTAssertNil(match("[SubsPlease] Sousou no Frieren (01-28) (1080p) [Batch]", f, 2, 5))
        XCTAssertNotNil(match("[Judas] Sousou no Frieren (Season 2) [1080p][HEVC x265 10bit][Multi-Subs] (Batch)", f, 2, 3))
        XCTAssertNotNil(match("[Judas] Sousou no Frieren [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Batch)", f, 1, 9))
    }

    func testRejectsSideStories() {
        let a = Self.aot
        XCTAssertNotNil(match("[Commie] Shingeki no Kyojin - 05 [E0567907].mkv", a, 1, 5))
        XCTAssertNil(match("[Erai-raws] Shingeki no Kyojin OAD - 05 [720p][Multiple Subtitle][E132256F].mkv", a, 1, 5))
        XCTAssertNotNil(match("[Erai-raws] Shingeki no Kyojin - The Final Season - 05 [1080p][Multiple Subtitle].mkv", a, 2, 5))
        XCTAssertNil(match("[Erai-raws] Shingeki no Kyojin - The Final Season - 05 [1080p][Multiple Subtitle].mkv", a, 1, 5))
        XCTAssertNil(match("[Anime Time] Attack on Titan Movie 05 - The Last Attack [BD] [Dual Audio][1080p] [Batch]", a, 1, 5))
        XCTAssertNil(match("[Group] Shingeki no Kyojin OST [FLAC]", a, 1, 5))
    }

    func testMovie() {
        let m = Show(id: 21519, title: "Your Name.", romaji: "Kimi no Na wa.", english: "Your Name.", format: "MOVIE",
                     status: "FINISHED", episodes: 1)
        let d = ShowDetails(show: m, seasons: [Self.season(m, 1, offset: 0)])
        XCTAssertNotNil(match("[Judas] Kimi no Na wa. (Your Name.) [BD 2160p 4K UHD][HEVC x265 10bit][Dual-Audio]", d, 1, 1))
        XCTAssertNil(match("[Group] Kimi no Na wa Fan Edit - 05", d, 1, 1))
    }

    func testTraits() {
        let t = ReleaseTraits.parse("[Judas] Sousou no Frieren [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Batch)")
        XCTAssertEqual(t.resolution, 1080)
        XCTAssertEqual(t.codec, "HEVC")
        XCTAssertTrue(t.is10bit)
        XCTAssertEqual(t.source, "Blu-ray")
        XCTAssertTrue(t.dualAudio)
        XCTAssertTrue(t.multiSubs)
        XCTAssertEqual(t.labels, ["HEVC 10-bit", "Blu-ray", "Dual Audio", "Multi-Sub"])

        let w = ReleaseTraits.parse("[Erai-raws] Sousou no Frieren 2nd Season - 05 [1080p CR WEB-DL AVC AAC][MultiSub][42940134]")
        XCTAssertEqual(w.codec, "AVC")
        XCTAssertEqual(w.source, "Web")
        XCTAssertEqual(w.audio, "AAC")
        XCTAssertTrue(w.multiSubs)

        let d = ReleaseTraits.parse("[Yameii] Frieren - S02E05 [English Dub] [CR WEB-DL 1080p H264 AAC]")
        XCTAssertTrue(d.dubbed)
        XCTAssertFalse(d.dualAudio)
        XCTAssertEqual(ReleaseTraits.parse("Show - 01 [4K]").resolution, 2160)
        XCTAssertEqual(ReleaseTraits.parse("Show - 01 [1920x1080 AV1 OPUS]").resolution, 1080)
        XCTAssertEqual(ReleaseTraits.parse("Show - 01 [1920x1080 AV1 OPUS]").codec, "AV1")
    }

    func testScorePrefersResolutionAndDub() {
        let base = SourcePreferences(resolution: 1080)
        let r = ReleaseName.parse("x")
        func s(_ name: String, _ p: SourcePreferences = base, seeders: Int = 100) -> Double {
            SourceFinder.score(Self.result(name, seeders: seeders), release: r, traits: .parse(name), isBatch: false, prefs: p)
        }
        XCTAssertGreaterThan(s("A - 01 (1080p)"), s("A - 01 (720p)"))
        XCTAssertGreaterThan(s("A - 01 (720p)", SourcePreferences(resolution: 720)), s("A - 01 (1080p)", SourcePreferences(resolution: 720)))
        XCTAssertGreaterThan(s("A - 01 (1080p)"), s("A - 01 [English Dub] (1080p)"))
        XCTAssertGreaterThan(s("A - 01 [Dual Audio] (1080p)", SourcePreferences(preferDub: true)), s("A - 01 (1080p)", SourcePreferences(preferDub: true)))
    }

    static func result(_ title: String, seeders: Int) -> NyaaResult {
        let html = """
        <table class="torrent-list"><tbody><tr class="default">
        <td><a href="/?c=1_2" title="Anime - English-translated"></a></td>
        <td colspan="2"><a href="/view/1" title="\(title)">\(title)</a></td>
        <td class="text-center"><a href="/download/1.torrent"></a><a href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"></a></td>
        <td class="text-center">1.0 GiB</td>
        <td class="text-center" data-timestamp="1700000000">2023-11-14 22:13</td>
        <td class="text-center">\(seeders)</td><td class="text-center">1</td><td class="text-center">10</td>
        </tr></tbody></table>
        """
        return try! NyaaParser.parse(html: html).results[0]
    }

    func testSeasonless() {
        XCTAssertEqual(ShowNames.seasonless("Sousou no Frieren 2nd Season"), "Sousou no Frieren")
        XCTAssertEqual(ShowNames.seasonless("Shingeki no Kyojin: The Final Season Part 2"), "Shingeki no Kyojin: The Final Season")
        XCTAssertEqual(ShowNames.seasonless("Mob Psycho 100 II"), "Mob Psycho 100")
        XCTAssertEqual(ShowNames.seasonless("Frieren: Beyond Journey’s End Season 2"), "Frieren: Beyond Journey’s End")
        XCTAssertEqual(SourceFinder.searchWords("Frieren: Beyond Journey’s End"), "Frieren Beyond Journey End")
        XCTAssertEqual(SourceFinder.searchWords("Kimetsu no Yaiba: Yuukaku-hen"), "Kimetsu no Yaiba Yuukaku hen")
    }

    func testQueries() {
        let f = Self.frieren
        let q2 = SourceFinder.queries(details: f, season: f.seasons[1], episode: f.seasons[1].episodes[4]).map(\.text)
        XCTAssertEqual(q2, ["Sousou no Frieren (05|33)", "Sousou no Frieren"])
        let q1 = SourceFinder.queries(details: f, season: f.seasons[0], episode: f.seasons[0].episodes[4]).map(\.text)
        XCTAssertEqual(q1, ["Sousou no Frieren 05", "Sousou no Frieren"])
    }

    func testFilePicker() {
        typealias F = EpisodeFilePicker.File
        let season = [
            F(index: 0, path: "[Judas] Frieren (Season 1)/[Judas] Sousou no Frieren - S01E01.mkv", length: 500),
            F(index: 1, path: "[Judas] Frieren (Season 1)/[Judas] Sousou no Frieren - S01E02.mkv", length: 500),
            F(index: 2, path: "[Judas] Frieren (Season 1)/Extras/[Judas] Sousou no Frieren - NCOP01.mkv", length: 50),
            F(index: 3, path: "[Judas] Frieren (Season 1)/[Judas] Sousou no Frieren - S01E05.mkv", length: 500),
            F(index: 4, path: "[Judas] Frieren (Season 1)/Fonts/arial.ttf", length: 5),
        ]
        XCTAssertEqual(EpisodeFilePicker.pick(season, season: 1, episode: 5, absolute: 5, seasonEpisodes: 28), 3)
        XCTAssertNil(EpisodeFilePicker.pick(season, season: 1, episode: 7, absolute: 7, seasonEpisodes: 28))

        let complete = [
            F(index: 0, path: "Show/Season 1/Show - 05.mkv", length: 500),
            F(index: 1, path: "Show/Season 2/Show - 05.mkv", length: 500),
            F(index: 2, path: "Show/Season 2/Show - NCED.mkv", length: 50),
        ]
        XCTAssertEqual(EpisodeFilePicker.pick(complete, season: 2, episode: 5, absolute: 33, seasonEpisodes: 10), 1)

        let absolute = (1...40).map { F(index: $0, path: "Show/[Grp] Show - \(String(format: "%02d", $0)) [1080p].mkv", length: 500) }
        XCTAssertEqual(EpisodeFilePicker.pick(absolute, season: 2, episode: 5, absolute: 33, seasonEpisodes: 10), 33)

        let unnumbered = ["Opening Night", "The Long Road", "Coda"].enumerated().map {
            F(index: $0.offset, path: "Pack/\($0.offset + 1). \($0.element).mkv", length: 500)
        }
        XCTAssertEqual(EpisodeFilePicker.pick(unnumbered.reversed(), season: 1, episode: 2, absolute: 2, seasonEpisodes: 3), 1)

        let movie = [F(index: 0, path: "M/sample.mkv", length: 10), F(index: 1, path: "M/Movie.mkv", length: 9000)]
        XCTAssertEqual(EpisodeFilePicker.pick(movie, season: 1, episode: 1, absolute: 1, seasonEpisodes: 1, isMovie: true), 1)
    }

    /// Hits Nyaa. Run with NYAA_LIVE=1.
    func testLiveSources() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NYAA_LIVE"] == "1")
        let finder = SourceFinder(nyaa: NyaaClient())
        let f = Self.frieren
        for (s, e) in [(1, 5), (2, 5)] {
            let season = f.seasons[s - 1]
            let found = try await finder.sources(for: f, season: season, episode: season.episodes[e - 1], prefs: SourcePreferences())
            print("S\(s)E\(e): \(found.count) sources")
            for src in found.prefix(8) {
                print(String(format: "  %6.1f", src.score), src.isBatch ? "batch" : "     ", src.result.seeders, src.result.title)
            }
            XCTAssertFalse(found.isEmpty)
            XCTAssertEqual(found.first?.traits.resolution, 1080)
        }
    }
}
