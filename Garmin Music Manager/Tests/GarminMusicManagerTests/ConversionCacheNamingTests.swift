import XCTest
@testable import GarminMusicCore

final class ConversionCacheNamingTests: XCTestCase {
    private func name(
        path: String = "/Music/ArtistA/01 Intro.flac",
        size: Int64 = 5_000_000,
        modified: Int64 = 1_700_000_000,
        bitrate: Int = 256,
        rate: String = "44100"
    ) -> String {
        ConversionCacheNaming.cacheFileName(
            sourcePath: path,
            sourceSizeBytes: size,
            sourceModifiedEpoch: modified,
            bitrateKbps: bitrate,
            sampleRateTag: rate
        )
    }

    func testIsDeterministicForIdenticalInputs() {
        XCTAssertEqual(name(), name())
    }

    func testUsesSanitizedSourceStemAndExtension() {
        let result = name(path: "/Music/ArtistA/01 Intro.flac")
        XCTAssertTrue(result.hasPrefix("01 Intro-"), result)
        XCTAssertTrue(result.hasSuffix("-b256-44100-converted.m4a"), result)
    }

    func testSameFileNameDifferentAlbumsDoNotCollide() {
        // Regression: two different sources sharing a base filename must map to
        // different cache files so reuse never returns the wrong audio.
        let a = name(path: "/Music/AlbumOne/01 Intro.flac", size: 5_000_000)
        let b = name(path: "/Music/AlbumTwo/01 Intro.flac", size: 7_500_000)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentModificationTimeChangesName() {
        XCTAssertNotEqual(name(modified: 1_700_000_000), name(modified: 1_700_000_001))
    }

    func testEncodeParametersChangeName() {
        XCTAssertNotEqual(name(bitrate: 256), name(bitrate: 128))
        XCTAssertNotEqual(name(rate: "44100"), name(rate: "48000"))
    }

    func testInvalidFileNameCharactersAreSanitized() {
        let result = name(path: "/Music/weird:name?.flac")
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("?"))
    }

    func testStableHashMatchesKnownFNV1aVector() {
        // FNV-1a 64-bit of "" is the offset basis; of "a" is 0xaf63dc4c8601ec8c.
        XCTAssertEqual(StableStringHash.hexDigest(of: ""), String(UInt64(0xcbf2_9ce4_8422_2325), radix: 16))
        XCTAssertEqual(StableStringHash.hexDigest(of: "a"), String(UInt64(0xaf63_dc4c_8601_ec8c), radix: 16))
    }
}
