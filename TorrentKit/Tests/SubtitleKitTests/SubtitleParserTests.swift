import XCTest
@testable import SubtitleKit

final class SubtitleParserTests: XCTestCase {
    private func parse(_ s: String, _ format: SubtitleFormat) -> [SubtitleCue] {
        SubtitleParser.parse(Data(s.utf8), format: format)
    }

    // MARK: formats

    func testFormatFromExtensionAndCodec() {
        XCTAssertEqual(SubtitleFormat(fileExtension: "SRT"), .srt)
        XCTAssertEqual(SubtitleFormat(fileExtension: ".vtt"), .vtt)
        XCTAssertEqual(SubtitleFormat(fileExtension: "WebVTT"), .vtt)
        XCTAssertEqual(SubtitleFormat(fileExtension: "ass"), .ass)
        XCTAssertEqual(SubtitleFormat(fileExtension: "Ssa"), .ass)
        XCTAssertNil(SubtitleFormat(fileExtension: "sub"))
        XCTAssertEqual(SubtitleFormat(codecID: "S_TEXT/UTF8"), .srt)
        XCTAssertEqual(SubtitleFormat(codecID: "S_TEXT/ASS"), .ass)
        XCTAssertEqual(SubtitleFormat(codecID: "S_TEXT/SSA"), .ass)
        XCTAssertEqual(SubtitleFormat(codecID: "S_ASS"), .ass)
        XCTAssertEqual(SubtitleFormat(codecID: "S_SSA"), .ass)
        XCTAssertEqual(SubtitleFormat(codecID: "S_TEXT/WEBVTT"), .vtt)
        XCTAssertNil(SubtitleFormat(codecID: "S_HDMV/PGS"))
        XCTAssertNil(SubtitleFormat(codecID: "S_VOBSUB"))
        XCTAssertNil(SubtitleFormat(codecID: "V_MPEG4/ISO/AVC"))
    }

    // MARK: SRT

    func testSRTBasicMultilineAndTags() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,500
        <i>Hello</i> <b>there</b>,
        <font color="#ffff00">General</font> {\\an8}Kenobi

        2
        00:01:02.250 --> 00:01:03.000
        a < b and c > d

        """
        let cues = parse(srt, .srt)
        XCTAssertEqual(cues, [
            SubtitleCue(start: 1, end: 4.5, text: "Hello there,\nGeneral Kenobi"),
            SubtitleCue(start: 62.25, end: 63, text: "a < b and c > d"),
        ])
    }

    func testSRTTolerance() {
        let srt = """


        00:00:05,000 --> 00:00:06,000 X1:100 X2:200 Y1:10 Y2:20
        No index line



        3
        0:00:07.5 --> 0:00:08.25
          Short fraction  

        4
        00:00:09,000 --> 00:00:10,000

        5
        00:00:02,000 --> 00:00:03,000
        Out of order
        """
        let cues = parse(srt, .srt)
        XCTAssertEqual(cues.map(\.text), ["Out of order", "No index line", "Short fraction"])
        XCTAssertEqual(cues.map(\.start), [2, 5, 7.5])
        XCTAssertEqual(cues[2].end, 8.25, accuracy: 1e-9)
    }

    func testSRTCRLFAndBOM() {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nLine one\r\nLine two\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nNext\r\n"
        let cues = parse(srt, .srt)
        XCTAssertEqual(cues.map(\.text), ["Line one\nLine two", "Next"])
    }

    func testUTF16Encodings() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nこんにちは\r\n"
        var le = Data([0xFF, 0xFE])
        var be = Data([0xFE, 0xFF])
        for u in srt.utf16 {
            le.append(contentsOf: [UInt8(u & 0xFF), UInt8(u >> 8)])
            be.append(contentsOf: [UInt8(u >> 8), UInt8(u & 0xFF)])
        }
        XCTAssertEqual(SubtitleParser.parse(le, format: .srt).first?.text, "こんにちは")
        XCTAssertEqual(SubtitleParser.parse(be, format: .srt).first?.text, "こんにちは")
    }

    func testLatin1AndWindows1252Fallback() {
        var data = Data("1\n00:00:01,000 --> 00:00:02,000\n".utf8)
        data.append(contentsOf: [0x43, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x6F, 0x6B, 0x94, 0x20, 0x80]) // Café “ok” €
        XCTAssertEqual(SubtitleParser.parse(data, format: .srt).first?.text, "Café \u{201C}ok\u{201D} €")
    }

    // MARK: WebVTT

    func testVTT() {
        let vtt = """
        WEBVTT - Some title
        Kind: captions

        NOTE This is a comment
        spanning lines

        STYLE
        ::cue { color: yellow }

        REGION
        id:fred width:40%

        intro-1
        00:01.000 --> 00:04.000 align:start position:10% line:0
        <v Roger Bingham>We are in New York City</v>
        <c.yellow.bg_blue>Coloured</c> &amp; &lt;escaped&gt;&nbsp;text

        00:00:05.000 --> 00:00:07.500
        <00:00:05.000>Karaoke <00:00:06.000><b>style</b>

        1:00:00.000 --> 1:00:01.000
        Hour
        """
        let cues = parse(vtt, .vtt)
        XCTAssertEqual(cues, [
            SubtitleCue(start: 1, end: 4, text: "We are in New York City\nColoured & <escaped> text"),
            SubtitleCue(start: 5, end: 7.5, text: "Karaoke style"),
            SubtitleCue(start: 3600, end: 3601, text: "Hour"),
        ])
    }

    func testVTTWithCRLFAndBOM() {
        let vtt = "\u{FEFF}WEBVTT\r\n\r\n00:00.500 --> 00:01.500\r\nHi &#233;&#x41;\r\n"
        XCTAssertEqual(parse(vtt, .vtt), [SubtitleCue(start: 0.5, end: 1.5, text: "Hi éA")])
    }

    // MARK: ASS

    private let assHeader = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour
    Style: Default,Arial,20,&H00FFFFFF

    """

    func testASSDialogueAndMarkup() {
        let ass = assHeader + """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\i1}Hello{\\i0}, world\\Nsecond\\hline
        Comment: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,This is a comment
        Dialogue: 0,0:00:04.00,0:00:05.00,Main,Bob,0,0,0,,Commas, everywhere, really
        Dialogue: 0,0:00:06.00,0:00:07.00,Italics,,0,0,0,,{\\an8}Top line
        Dialogue: 0,0:00:08.00,0:00:09.00,Flashback,,0,0,0,,{comment block}Shown\\nwrapped
        Dialogue: 0,0:00:10.00,0:00:11.00,Top,,0,0,0,,Top style
        Dialogue: 0,0:00:12.00,0:00:13.00,Alt,,0,0,0,,{\\fad(200,200)}Alt style
        Dialogue: 0,1:02:03.45,1:02:04.00,Default,,0,0,0,,Late
        """
        let cues = parse(ass, .ass)
        XCTAssertEqual(cues.map(\.text), [
            "Hello, world\nsecond line",
            "Commas, everywhere, really",
            "Top line",
            "Shown\nwrapped",
            "Top style",
            "Alt style",
            "Late",
        ])
        XCTAssertEqual(cues[0].start, 1)
        XCTAssertEqual(cues[0].end, 3.5)
        XCTAssertEqual(cues[6].start, 3723.45, accuracy: 1e-9)
    }

    func testASSDropsTypesettingAndSignStyles() {
        let ass = assHeader + """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\pos(100,200)}Shop sign
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\move(1,2,3,4)}Moving
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\org(1,2)\\frz10}Rotated
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\clip(0,0,10,10)}Clipped
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\k20}Ka{\\k30}ra{\\kf10}oke
        Dialogue: 0,0:00:01.00,0:00:02.00,Signs,,0,0,0,,Sign style
        Dialogue: 0,0:00:01.00,0:00:02.00,Sign_Board,,0,0,0,,Sign board
        Dialogue: 0,0:00:01.00,0:00:02.00,OP Romaji,,0,0,0,,Opening lyrics
        Dialogue: 0,0:00:01.00,0:00:02.00,ED-English,,0,0,0,,Ending lyrics
        Dialogue: 0,0:00:01.00,0:00:02.00,SongTL,,0,0,0,,Song translation
        Dialogue: 0,0:00:01.00,0:00:02.00,Karaoke,,0,0,0,,Karaoke style
        Dialogue: 0,0:00:01.00,0:00:02.00,kfx,,0,0,0,,Effects
        Dialogue: 0,0:00:01.00,0:00:02.00,Title,,0,0,0,,Episode title
        Dialogue: 0,0:00:01.00,0:00:02.00,OPRomaji,,0,0,0,,Camel case
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\b1\\fs40\\pbo0}Kept dialogue
        Dialogue: 0,0:00:01.00,0:00:02.00,Overlap,,0,0,0,,Overlap is dialogue
        """
        XCTAssertEqual(parse(ass, .ass).map(\.text), ["Kept dialogue\nOverlap is dialogue"])
    }

    func testASSMergesSimultaneousDuplicates() {
        let ass = assHeader + """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 1,0:00:05.00,0:00:06.00,Default,,0,0,0,,Same line
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\bord5}Same line
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,Other speaker
        Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,Different end
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Earlier
        """
        let cues = parse(ass, .ass)
        XCTAssertEqual(cues, [
            SubtitleCue(start: 1, end: 2, text: "Earlier", style: "Default"),
            SubtitleCue(start: 5, end: 6, text: "Same line\nOther speaker", style: "Default"),
            SubtitleCue(start: 5, end: 7, text: "Different end", style: "Default"),
        ])
    }

    func testSSAWithCustomFormatOrder() {
        let ssa = """
        [Script Info]
        ScriptType: v4.00

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:01.00,0:00:02.00,*Default,NTP,0000,0000,0000,!Effect,SSA, line
        """
        XCTAssertEqual(parse(ssa, .ass), [SubtitleCue(start: 1, end: 2, text: "SSA, line", style: "*Default")])

        let reordered = """
        [Events]
        Format: Start, End, Text, Style
        Dialogue: 0:00:03.00,0:00:04.00,Text first,Default
        """
        // Text is matched by name even when it isn't the last column.
        XCTAssertEqual(parse(reordered, .ass), [SubtitleCue(start: 3, end: 4, text: "Text first", style: "Default")])
    }

    func testASSStyleWords() {
        let dialogue = ["Default", "Main", "Italics", "Flashback", "Top", "Alt", "Default - Top", "Narrator", "Thoughts",
                        "Overlap", "Editorial", "Speed", "Notes"]
        for s in dialogue { XCTAssertFalse(ASSScript.isSignStyle(Substring(s)), s) }
        let signs = ["Sign", "signs", "Song_Romaji", "OP", "ed", "OP1", "ED2 Kanji", "Opening", "Karaoke", "KFX", "Title",
                     "TS", "Lyrics", "Default-Sign", "SongEN"]
        for s in signs { XCTAssertTrue(ASSScript.isSignStyle(Substring(s)), s) }
    }

    func testCueTextEdgeCases() {
        XCTAssertEqual(parse("1\n00:00:01,000 --> 00:00:02,000\n<i></i>\n", .srt), [], "empty cues are dropped")
        XCTAssertEqual(parse("garbage\nmore garbage", .srt), [])
        XCTAssertEqual(parse("WEBVTT\n", .vtt), [])
        XCTAssertEqual(parse("", .ass), [])
    }
}
