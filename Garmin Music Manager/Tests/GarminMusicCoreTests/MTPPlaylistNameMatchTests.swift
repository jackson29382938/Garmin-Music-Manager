import XCTest
@testable import GarminMusicCore

final class MTPPlaylistNameMatchTests: XCTestCase {
    func testMatchesCaseInsensitively() {
        let names: [(id: UInt32, name: String)] = [
            (10, "Long Run"),
            (11, "Cool Down")
        ]
        XCTAssertEqual(MTPPlaylistNameMatch.existingID(named: "long run", names: names), 10)
        XCTAssertEqual(MTPPlaylistNameMatch.existingID(named: "COOL DOWN", names: names), 11)
    }

    func testReturnsNilWhenMissing() {
        let names: [(id: UInt32, name: String)] = [(10, "Long Run")]
        XCTAssertNil(MTPPlaylistNameMatch.existingID(named: "Tempo", names: names))
    }

    func testPrefersFirstMatch() {
        let names: [(id: UInt32, name: String)] = [
            (1, "Mix"),
            (2, "mix")
        ]
        XCTAssertEqual(MTPPlaylistNameMatch.existingID(named: "MIX", names: names), 1)
    }
}
