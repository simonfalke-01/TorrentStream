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

    /// Uncensored adult releases are on Sukebei, not Nyaa.
    func testAdultShowsAlsoSearchSukebei() {
        let o = Show(id: 113417, title: "Overflow", romaji: "Overflow", english: "Overflow", format: "ONA",
                     status: "FINISHED", episodes: 8, isAdult: true)
        let d = ShowDetails(show: o, seasons: [Self.season(o, 1, offset: 0)])
        let qs = SourceFinder.queries(details: d, season: d.seasons[0], episode: d.seasons[0].episodes[7])
        XCTAssertEqual(qs.filter { !$0.adult }.map(\.text), qs.filter(\.adult).map(\.text))
        XCTAssertTrue(qs.filter(\.adult).allSatisfy { $0.category.id == "1_1" })
        XCTAssertTrue(qs.first.map { !$0.adult } ?? false, "the episode's own Nyaa search stays first")
        XCTAssertFalse(SourceFinder.queries(details: Self.frieren, season: Self.frieren.seasons[0],
                                            episode: Self.frieren.seasons[0].episodes[0]).contains(where: \.adult))
        XCTAssertNotNil(match("[HentaiHub] Overflow S01E08 1080p UNCENSORED OV WEB-DL AAC2.0 H.264 (English Dub)", d, 1, 8))
        XCTAssertNotNil(match("[Doomdos] - Overflow - 08 [Uncensored] [Dub] [1080p OV WEB-DL]", d, 1, 8))
        XCTAssertEqual(NyaaQuery(text: "Overflow", adult: true).url(base: NyaaClient.adultBaseURL, page: 1).host,
                       "sukebei.nyaa.si")
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

    func testConfidentPick() {
        func src(_ name: String, seeders: Int, batch: Bool = false) -> EpisodeSource {
            EpisodeSource(result: Self.result(name, seeders: seeders), release: ReleaseName.parse(name), traits: .parse(name),
                          isBatch: batch, score: 0)
        }
        let prefs = SourcePreferences()
        let good = src("[SubsPlease] A - 01 (1080p) [ABCD1234].mkv", seeders: 40)
        XCTAssertTrue(SourceFinder.isConfident(good, prefs: prefs, episodeSearched: false))
        XCTAssertTrue(SourceFinder.isConfident(src("[SubsPlease] A - 01 (1080p)", seeders: 12), prefs: prefs, episodeSearched: true))
        // Before the episode's own search answers: only a large single-episode swarm.
        XCTAssertFalse(SourceFinder.isConfident(src("[SubsPlease] A - 01 (1080p)", seeders: 12), prefs: prefs, episodeSearched: false))
        XCTAssertFalse(SourceFinder.isConfident(src("[Group] A (01-12) (1080p)", seeders: 200, batch: true), prefs: prefs,
                                                episodeSearched: false))
        XCTAssertFalse(SourceFinder.isConfident(src("[SubsPlease] A - 01 (1080p)", seeders: 3), prefs: prefs, episodeSearched: true))
        XCTAssertFalse(SourceFinder.isConfident(src("[SubsPlease] A - 01 (720p)", seeders: 100), prefs: prefs, episodeSearched: true))
        XCTAssertFalse(SourceFinder.isConfident(good, prefs: SourcePreferences(group: "Erai-raws"), episodeSearched: true))
        XCTAssertTrue(SourceFinder.isConfident(good, prefs: SourcePreferences(group: "SubsPlease"), episodeSearched: true))
        XCTAssertFalse(SourceFinder.isConfident(good, prefs: SourcePreferences(preferDub: true), episodeSearched: true))
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

    // MARK: OVAs and specials

    static let nukitashiTV = Show(id: 174188, title: "Nukitashi THE ANIMATION", romaji: "Nukitashi THE ANIMATION",
                                  english: "Nukitashi THE ANIMATION", format: "TV", status: "FINISHED", episodes: 11, isAdult: true)
    /// AniList files the OVAs as an entry of their own, named with "OVAs", which no release uses.
    static func nukitashiOVA(parent: Bool = true) -> ShowDetails {
        let ova = Show(id: 194712, title: "Nukitashi THE ANIMATION OVAs", romaji: "Nukitashi THE ANIMATION OVAs",
                       format: "OVA", status: "FINISHED", episodes: 4, isAdult: true)
        return ShowDetails(show: ova, seasons: [season(ova, 1, offset: 0)], parent: parent ? nukitashiTV : nil)
    }

    func testSpecialReleaseNames() {
        let a = ReleaseName.parse("[Raze] Nukitashi The Animation - Specials 01-02 (BD) x265 10bit 1080p 143.8561fps")
        XCTAssertEqual(a.title, "Nukitashi The Animation")
        XCTAssertTrue(a.isSpecial)
        XCTAssertEqual(a.episode, 1)
        XCTAssertEqual(a.lastEpisode, 2)

        let b = ReleaseName.parse("[Zemblanity] Nukitashi THE ANIMATION - S00E01-E04 (BD 1080p AV1 Opus)")
        XCTAssertTrue(b.isSpecial)
        XCTAssertEqual(b.season, 0)
        XCTAssertEqual(b.lastEpisode, 4)

        let c = ReleaseName.parse("[anon] Nukitashi Specials 03-04 (BD 1080p AVC FLAC) | ぬきたし EX 03-04")
        XCTAssertEqual(c.title, "Nukitashi")
        XCTAssertEqual(c.episode, 3)
        XCTAssertEqual(c.lastEpisode, 4)

        let d = ReleaseName.parse("[Hentai] Nukitashi the Animation - (11 EPs + 4 OVA) (BDRip 1080p) (Batch)")
        XCTAssertEqual(d.title, "Nukitashi the Animation")
        XCTAssertFalse(d.isSpecial)
        XCTAssertTrue(d.includesSpecials)

        let e = ReleaseName.parse("[Erai-raws] Shingeki no Kyojin OAD - 05 [720p][Multiple Subtitle][E132256F].mkv")
        XCTAssertEqual(e.title, "Shingeki no Kyojin")
        XCTAssertTrue(e.isSpecial)
        XCTAssertEqual(e.episode, 5)

        XCTAssertTrue(ReleaseName.parse("[Group] Show S01 + OVA [1080p]").includesSpecials)
        XCTAssertFalse(ReleaseName.parse("[Group] Show S01 + OVA [1080p]").isSpecial)
        XCTAssertTrue(ReleaseName.parse("[Group] Show (OVA) [1080p]").isSpecial)
        XCTAssertEqual(ReleaseName.parse("[Group] Show OVA [1080p]").title, "Show")
        XCTAssertEqual(ReleaseName.parse("[Group] Show - SP2 [1080p].mkv").episode, 2)
        // A name that starts with the word isn't a special.
        XCTAssertFalse(ReleaseName.parse("[Group] Special 7 - 05 [1080p]").isSpecial)
        XCTAssertFalse(ReleaseName.parse("[SubsPlease] Spy x Family - 05 (1080p)").isSpecial)
    }

    func testMatchesSpecialsUnderTheSeriesName() {
        for d in [Self.nukitashiOVA(), Self.nukitashiOVA(parent: false)] {
            XCTAssertEqual(match("[Raze] Nukitashi The Animation - Specials 01-02 (BD) x265 10bit 1080p", d, 1, 2)?.isBatch, true)
            XCTAssertNil(match("[Raze] Nukitashi The Animation - Specials 01-02 (BD) x265 10bit 1080p", d, 1, 3))
            XCTAssertNotNil(match("[Zemblanity] Nukitashi THE ANIMATION - S00E01-E04 (BD 1080p AV1 Opus)", d, 1, 3))
            XCTAssertNotNil(match("[anon] Nukitashi Specials 03-04 (BD 1080p AVC FLAC) | ぬきたし EX 03-04", d, 1, 4))
            XCTAssertEqual(match("[Hentai] Nukitashi the Animation - (11 EPs + 4 OVA) (BDRip 1080p) (Batch)", d, 1, 1)?.isBatch, true)
            // The series' own releases aren't the OVAs.
            XCTAssertNil(match("Nukitashi the Animation S01 1080p BluRay Dual-Audio Opus 2.0 x265-StaFer", d, 1, 1))
            XCTAssertNil(match("[ToonsHub] NUKITASHI THE ANIMATION S01E01 1080p UNCENSORED CTHP WEB-DL", d, 1, 1))
            XCTAssertNil(match("[denisplay] Nukitashi The Animation - 01 [1080p] [AV1]", d, 1, 1))
            XCTAssertNil(match("[Hentai] Nukitashi the Animation (BD 1080p Opus 2.0 x265) [Dual Audio] (Batch)", d, 1, 1))
        }
        // And the series doesn't take its specials for episodes.
        let tv = ShowDetails(show: Self.nukitashiTV, seasons: [Self.season(Self.nukitashiTV, 1, offset: 0)])
        XCTAssertNil(match("[Raze] Nukitashi The Animation - Specials 01-02 (BD) x265 10bit 1080p", tv, 1, 1))
        XCTAssertNil(match("[Zemblanity] Nukitashi THE ANIMATION - S00E01-E04 (BD 1080p AV1 Opus)", tv, 1, 1))
        XCTAssertNotNil(match("[Hentai] Nukitashi the Animation - (11 EPs + 4 OVA) (BDRip 1080p) (Batch)", tv, 1, 5))
    }

    /// An OVA series under a name of its own plays from releases under that name.
    func testOVASeriesWithItsOwnName() {
        let h = Show(id: 777, title: "Hellsing Ultimate", romaji: "Hellsing Ultimate", english: "Hellsing Ultimate",
                     format: "OVA", status: "FINISHED", episodes: 10)
        let d = ShowDetails(show: h, seasons: [Self.season(h, 1, offset: 0)])
        XCTAssertNotNil(match("[Group] Hellsing Ultimate - 03 [BD 1080p].mkv", d, 1, 3))
        XCTAssertNil(match("[Group] Hellsing Ultimate - 04 [BD 1080p].mkv", d, 1, 3))
        XCTAssertNotNil(match("[Group] Hellsing Ultimate (01-10) [BD 1080p]", d, 1, 3))
        let qs = SourceFinder.queries(details: d, season: d.seasons[0], episode: d.seasons[0].episodes[2]).map(\.text)
        XCTAssertEqual(qs, ["Hellsing Ultimate \(SourceFinder.specialWords)", "Hellsing Ultimate"])
    }

    /// A sequel's OVA isn't the first season's, and the other way round.
    func testSpecialsKeepToTheirSeason() {
        let s3 = ReleaseName.parse("[Erai-raws] Kono Subarashii Sekai ni Shukufuku wo! 3 - OVA 01 [1080p CR WEBRip HEVC EAC3][MultiSub][03309776]")
        XCTAssertEqual(s3.season, 3)
        XCTAssertEqual(s3.title, "Kono Subarashii Sekai ni Shukufuku wo!")
        XCTAssertEqual(ReleaseName.parse("[Erai-raws] Kono Subarashii Sekai ni Shukufuku wo! 2 - OVA [1080p].mkv").season, 2)
        XCTAssertEqual(ReleaseName.parse("[Anime Time] Kaguya Sama - Love Is War Season 02 OVA [1080p][HEVC 10bit x265]").season, 2)
        XCTAssertTrue(ReleaseName.parse("[SubsPlease] Mushoku Tensei S2 - OVA [1080p]").isSpecial)
        XCTAssertEqual(ShowNames.seasonNumber("Kono Subarashii Sekai ni Shukufuku wo! 2"), 2)
        XCTAssertEqual(ShowNames.seasonNumber("Kaguya-sama: Love is War Season 2"), 2)
        XCTAssertNil(ShowNames.seasonNumber("Mob Psycho 100"))

        func konosuba(_ parentTitle: String) -> ShowDetails {
            let ova = Show(id: 1, title: "Kono Subarashii Sekai ni Shukufuku wo! OVA", romaji: "Kono Subarashii Sekai ni Shukufuku wo! OVA",
                           format: "OVA", status: "FINISHED", episodes: 1)
            let parent = Show(id: 2, title: parentTitle, romaji: parentTitle, format: "TV", status: "FINISHED", episodes: 10)
            return ShowDetails(show: ova, seasons: [Self.season(ova, 1, offset: 0)], parent: parent)
        }
        let first = konosuba("Kono Subarashii Sekai ni Shukufuku wo!")
        XCTAssertNotNil(match("[Erai-raws] Kono Subarashii Sekai ni Shukufuku wo! - OVA [1080p][Multiple Subtitle].mkv", first, 1, 1))
        XCTAssertNil(match("[Erai-raws] Kono Subarashii Sekai ni Shukufuku wo! 2 - OVA [1080p][Multiple Subtitle].mkv", first, 1, 1))
        XCTAssertNil(match("[Erai-raws] Kono Subarashii Sekai ni Shukufuku wo! 3 - OVA 01 [1080p CR WEBRip HEVC EAC3]", first, 1, 1))
        XCTAssertNil(match("[Foxtrot] Kono Subarashii Sekai ni Shukufuku wo! S2 + OVA [BD 1080p FLAC]", first, 1, 1))
        let second = konosuba("Kono Subarashii Sekai ni Shukufuku wo! 2")
        XCTAssertNotNil(match("[Erai-raws] Kono Subarashii Sekai ni Shukufuku wo! 2 - OVA [1080p][Multiple Subtitle].mkv", second, 1, 1))
        XCTAssertNil(match("[Erai-raws] Kono Subarashii Sekai ni Shukufuku wo! 3 - OVA 01 [1080p CR WEBRip HEVC EAC3]", second, 1, 1))
    }

    func testSpecialQueriesDropTheFormatWord() {
        let d = Self.nukitashiOVA()
        let qs = SourceFinder.queries(details: d, season: d.seasons[0], episode: d.seasons[0].episodes[0])
        let nyaa = qs.filter { !$0.adult }.map(\.text)
        XCTAssertEqual(nyaa, ["Nukitashi THE ANIMATION \(SourceFinder.specialWords)", "Nukitashi \(SourceFinder.specialWords)"])
        XCTAssertEqual(qs.filter(\.adult).count, nyaa.count, "adult, so Sukebei too")
        XCTAssertEqual(ShowNames.withoutSideMarker("Kaguya-sama wa Kokurasetai OVA"), "Kaguya-sama wa Kokurasetai")
        XCTAssertEqual(ShowNames.withoutSideMarker("Hellsing Ultimate"), "Hellsing Ultimate")
    }

    func testSpecialFilePicker() {
        typealias F = EpisodeFilePicker.File
        // The series with its OVAs: the OVA, not the series' episode of the same number.
        let complete = (1...11).map { F(index: $0, path: "[Hentai] Nukitashi (11 EPs + 4 OVA)/Nukitashi - \(String(format: "%02d", $0)).mkv", length: 500) }
            + (1...4).map { F(index: 20 + $0, path: "[Hentai] Nukitashi (11 EPs + 4 OVA)/OVA/Nukitashi OVA \($0).mkv", length: 400) }
        XCTAssertEqual(EpisodeFilePicker.pick(complete, season: 1, episode: 2, absolute: 2, seasonEpisodes: 4, special: true), 22)
        // Only the specials, numbered as season 0.
        let specials = (1...4).map { F(index: $0, path: "Nukitashi S00/Nukitashi THE ANIMATION - S00E0\($0).mkv", length: 400) }
        XCTAssertEqual(EpisodeFilePicker.pick(specials, season: 1, episode: 3, absolute: 3, seasonEpisodes: 4, special: true), 3)
        // Only the specials, numbered plainly.
        let plain = (1...2).map { F(index: $0, path: "[Raze] Nukitashi - Specials 01-02/[Raze] Nukitashi - 0\($0).mkv", length: 400) }
            + [F(index: 9, path: "[Raze] Nukitashi - Specials 01-02/NCOP.mkv", length: 50)]
        XCTAssertEqual(EpisodeFilePicker.pick(plain, season: 1, episode: 2, absolute: 2, seasonEpisodes: 4, special: true), 2)
    }

    /// Hits Nyaa and Sukebei. Run with NYAA_LIVE=1.
    func testLiveSpecials() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NYAA_LIVE"] == "1")
        let d = Self.nukitashiOVA()
        let season = d.seasons[0]
        let found = try await SourceFinder(nyaa: NyaaClient()).sources(for: d, season: season, episode: season.episodes[0],
                                                                     prefs: SourcePreferences())
        for src in found.prefix(8) { print(src.isBatch ? "batch" : "     ", src.result.seeders, src.result.title) }
        XCTAssertFalse(found.isEmpty)
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
