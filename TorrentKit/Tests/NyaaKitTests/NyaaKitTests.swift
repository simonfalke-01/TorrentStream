import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NyaaKit

final class NyaaKitTests: XCTestCase {
    // Two rows copied from the live site's markup: a trusted upload with comments and a remake.
    static let fixture = """
    <table class="table torrent-list"><tbody>
    \t\t\t<tr class="success">
    \t\t\t\t<td>
    \t\t\t\t\t<a href="/?c=1_2" title="Anime - English-translated">
    \t\t\t\t\t\t<img src="/static/img/icons/nyaa/1_2.png" alt="Anime - English-translated" class="category-icon">
    \t\t\t\t\t</a>
    \t\t\t\t</td>
    \t\t\t\t<td colspan="2">
    \t\t\t\t\t<a href="/view/2090638#comments" class="comments" title="11 comments">
    \t\t\t\t\t\t<i class="fa fa-comments-o"></i>11</a>
    \t\t\t\t\t<a href="/view/2090638" title="[Erai-raws] Frieren &amp; Friends - 10 [1080p]&#39;s">[Erai-raws] Frieren &amp; Friends - 10 [1080p]&#39;s</a>
    \t\t\t\t</td>
    \t\t\t\t<td class="text-center">
    \t\t\t\t\t<a href="/download/2090638.torrent"><i class="fa fa-fw fa-download"></i></a>
    \t\t\t\t\t<a href="magnet:?xt=urn:btih:BD167D148570F2C7ECE6C15BD90D3901ACB6D79C&amp;dn=Frieren&amp;tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce"><i class="fa fa-fw fa-magnet"></i></a>
    \t\t\t\t</td>
    \t\t\t\t<td class="text-center">1.4 GiB</td>
    \t\t\t\t<td class="text-center" data-timestamp="1774623653">2026-03-27 15:00</td>

    \t\t\t\t<td class="text-center">647</td>
    \t\t\t\t<td class="text-center">2</td>
    \t\t\t\t<td class="text-center">35213</td>
    \t\t\t</tr>
    \t\t\t<tr class="danger">
    \t\t\t\t<td>
    \t\t\t\t\t<a href="/?c=4_4" title="Live Action - Raw">
    \t\t\t\t\t</a>
    \t\t\t\t</td>
    \t\t\t\t<td colspan="2">
    \t\t\t\t\t<a href="/view/17" title="Remade thing">Remade thing</a>
    \t\t\t\t</td>
    \t\t\t\t<td class="text-center">
    \t\t\t\t\t<a href="/download/17.torrent"><i class="fa fa-fw fa-download"></i></a>
    \t\t\t\t\t<a href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&amp;dn=x"><i class="fa fa-fw fa-magnet"></i></a>
    \t\t\t\t</td>
    \t\t\t\t<td class="text-center">512.0 MiB</td>
    \t\t\t\t<td class="text-center" data-timestamp="1600000000">2020-09-13 12:26</td>
    \t\t\t\t<td class="text-center">0</td>
    \t\t\t\t<td class="text-center">0</td>
    \t\t\t\t<td class="text-center">3</td>
    \t\t\t</tr>
    </tbody></table>
    <div class="pagination-page-info">Displaying results 1-75 out of 1,000 results.<br>
    <ul class="pagination"><li class="active"><a>1</a></li><li class="next"><a href="/?f=0&c=0_0&q=frieren&s=seeders&o=desc&p=2">&raquo;</a></li></ul>
    """

    func testParsesRows() throws {
        let page = try NyaaParser.parse(html: Self.fixture)
        XCTAssertEqual(page.results.count, 2)
        XCTAssertTrue(page.hasNextPage)
        XCTAssertEqual(page.totalResults, 1000)

        let a = page.results[0]
        XCTAssertEqual(a.id, 2090638)
        XCTAssertEqual(a.title, "[Erai-raws] Frieren & Friends - 10 [1080p]'s")
        XCTAssertEqual(a.category.id, "1_2")
        XCTAssertEqual(a.trust, .trusted)
        XCTAssertEqual(a.size, Int64(1.4 * 1024 * 1024 * 1024))
        XCTAssertEqual(a.date, Date(timeIntervalSince1970: 1774623653))
        XCTAssertEqual(a.seeders, 647)
        XCTAssertEqual(a.leechers, 2)
        XCTAssertEqual(a.downloads, 35213)
        XCTAssertEqual(a.comments, 11)
        XCTAssertEqual(a.infoHash, "bd167d148570f2c7ece6c15bd90d3901acb6d79c")
        XCTAssertEqual(a.magnet?.contains("&amp;"), false)
        XCTAssertEqual(a.torrentURL?.absoluteString, "https://nyaa.si/download/2090638.torrent")
        XCTAssertEqual(a.pageURL.absoluteString, "https://nyaa.si/view/2090638")

        let b = page.results[1]
        XCTAssertEqual(b.trust, .remake)
        XCTAssertEqual(b.category.id, "4_4")
        XCTAssertEqual(b.comments, 0)
        XCTAssertEqual(b.size, 512 * 1024 * 1024)
        XCTAssertEqual(b.seeders, 0)
    }

    func testEmptyAndLastPage() throws {
        let none = try NyaaParser.parse(html: """
        <div class="pagination-page-info">Displaying results 0-0 out of 0 results.</div><h3>No results found</h3>
        """)
        XCTAssertTrue(none.results.isEmpty)
        XCTAssertFalse(none.hasNextPage)
        XCTAssertEqual(none.totalResults, 0)

        let last = try NyaaParser.parse(html: Self.fixture.replacingOccurrences(
            of: #"<li class="next"><a href="/?f=0&c=0_0&q=frieren&s=seeders&o=desc&p=2">&raquo;</a></li>"#,
            with: #"<li class="next disabled"><a> &raquo; </a></li>"#))
        XCTAssertFalse(last.hasNextPage)
    }

    func testRejectsUnrelatedPages() {
        XCTAssertThrowsError(try NyaaParser.parse(html: "<html><body>Cloudflare challenge</body></html>"))
    }

    func testQueryURL() {
        let q = NyaaQuery(text: "  frieren 1080p ", category: NyaaCategory.find("1_2"), filter: .trustedOnly,
                          sort: .size, ascending: true)
        let url = q.url(base: NyaaClient.defaultBaseURL, page: 3).absoluteString
        XCTAssertEqual(url, "https://nyaa.si/?f=2&c=1_2&q=frieren%201080p&s=size&o=asc&p=3")
        XCTAssertEqual(NyaaQuery(text: "x", sort: .date).url(base: NyaaClient.defaultBaseURL, page: 1).query,
                       "f=0&c=0_0&q=x&s=id&o=desc&p=1")
    }

    func testEntities() {
        XCTAssertEqual(NyaaParser.decodeEntities("a &amp; b &#34;c&#34; &#x27;d&#x27; &unknown; &"), "a & b \"c\" 'd' &unknown; &")
    }

    /// Hits the real site to confirm server-side sorting. Run with NYAA_LIVE=1.
    func testLiveSorting() async throws {
        guard ProcessInfo.processInfo.environment["NYAA_LIVE"] == "1" else { throw XCTSkip("set NYAA_LIVE=1") }
        let client = NyaaClient()
        for (sort, key) in [(NyaaSort.seeders, \NyaaResult.seeders), (.downloads, \.downloads), (.leechers, \.leechers)] {
            for asc in [false, true] {
                let page = try await client.search(NyaaQuery(text: "frieren", sort: sort, ascending: asc))
                XCTAssertFalse(page.results.isEmpty)
                let values = page.results.map { $0[keyPath: key] }
                XCTAssertEqual(values, asc ? values.sorted() : values.sorted(by: >), "\(sort) asc=\(asc)")
            }
        }
        let bySize = try await client.search(NyaaQuery(text: "frieren", sort: .size))
        let sizes = bySize.results.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        let byDate = try await client.search(NyaaQuery(text: "frieren", sort: .date))
        // "Date" is upload order (torrent id); neighbouring timestamps can differ by seconds.
        let ids = byDate.results.map(\.id)
        XCTAssertEqual(ids, ids.sorted(by: >))
        XCTAssertTrue(byDate.hasNextPage)
        let page2 = try await client.search(NyaaQuery(text: "frieren", sort: .date), page: 2)
        XCTAssertLessThan(page2.results.first!.id, ids.last!)
        XCTAssertTrue(Set(page2.results.map(\.id)).isDisjoint(with: ids))

        let data = try await client.torrentData(for: byDate.results[0])
        XCTAssertEqual(data.first, UInt8(ascii: "d"))
    }
}
