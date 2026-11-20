import XCTest
@testable import SubtitleKit

final class SubtitleLabelsTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(SubtitleLabels.label(language: "eng", name: nil, fallbackIndex: 1), "English")
        XCTAssertEqual(SubtitleLabels.label(language: "jpn", name: "Japanese", fallbackIndex: 1), "Japanese")
        XCTAssertEqual(SubtitleLabels.label(language: "eng", name: "Signs & Songs", fallbackIndex: 1), "English (Signs & Songs)")
        XCTAssertEqual(SubtitleLabels.label(language: nil, name: nil, fallbackIndex: 3), "Track 3")
        XCTAssertEqual(SubtitleLabels.label(language: nil, name: "  ", fallbackIndex: 4), "Track 4")
        XCTAssertEqual(SubtitleLabels.label(language: nil, name: "Commentary", fallbackIndex: 2), "Commentary")
        XCTAssertEqual(SubtitleLabels.label(language: "und", name: nil, fallbackIndex: 5), "Track 5")
        XCTAssertEqual(SubtitleLabels.label(language: "eng", name: "eng", fallbackIndex: 1), "English")
        XCTAssertEqual(SubtitleLabels.label(language: "eng", name: "en", fallbackIndex: 1), "English")
        XCTAssertEqual(SubtitleLabels.label(language: "eng", name: "English - Full", fallbackIndex: 1), "English - Full")
        XCTAssertEqual(SubtitleLabels.label(language: "en", name: nil, fallbackIndex: 1), "English")
        XCTAssertEqual(SubtitleLabels.label(language: "pt-BR", name: nil, fallbackIndex: 1), "Portuguese (Brazil)")
        XCTAssertEqual(SubtitleLabels.label(language: "spa", name: "Latin America", fallbackIndex: 1), "Spanish (Latin America)")
    }

    func testISO639_2Mapping() {
        let expected = [
            "eng": "English", "jpn": "Japanese", "spa": "Spanish", "por": "Portuguese", "fre": "French", "fra": "French",
            "ger": "German", "deu": "German", "ita": "Italian", "rus": "Russian", "ara": "Arabic", "chi": "Chinese",
            "zho": "Chinese", "kor": "Korean", "pol": "Polish", "tur": "Turkish", "vie": "Vietnamese", "tha": "Thai",
            "ind": "Indonesian", "may": "Malay", "msa": "Malay", "hin": "Hindi", "heb": "Hebrew", "dut": "Dutch",
            "nld": "Dutch", "swe": "Swedish", "nor": "Norwegian", "dan": "Danish", "fin": "Finnish", "ukr": "Ukrainian",
            "cze": "Czech", "ces": "Czech", "hun": "Hungarian", "rum": "Romanian", "ron": "Romanian", "gre": "Greek", "ell": "Greek",
        ]
        for (code, name) in expected {
            XCTAssertEqual(SubtitleLabels.label(language: code, name: nil, fallbackIndex: 1), name, code)
        }
    }

    func testSignsOnly() {
        for name in ["Signs & Songs", "signs/songs", "Signs", "SONGS", "Forced", "S&S", "English (S & S)", "Signs and Songs",
                     "[Signs]", "Eng - Forced"] {
            XCTAssertTrue(SubtitleLabels.isSignsOnly(name: name), name)
        }
        for name in [nil, "", "English", "Full Subtitles", "Dialogue + Signs", "Full (incl. Signs & Songs)", "Designs",
                     "Songbird", "Dubs & Subs", "SDH"] as [String?] {
            XCTAssertFalse(SubtitleLabels.isSignsOnly(name: name), name ?? "nil")
        }
    }
}
