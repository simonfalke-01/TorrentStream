import XCTest
@testable import SkipKit

final class AudioPrintTests: XCTestCase {
    func testPrintRoundTripsThroughCodable() throws {
        var p = AudioPrint()
        p.set(3, code: 0xDEAD_BEEF, quiet: false)
        p.set(5, code: 7, quiet: true)
        let back = try JSONDecoder().decode(AudioPrint.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.states, [.unknown, .unknown, .unknown, .known, .unknown, .quiet])
    }
}
