import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

final class TrackMatchingTests: XCTestCase {
    func testNameAndSizeMatch() {
        XCTAssertTrue(
            TrackMatching.isIdentical(
                localFileName: "Song.mp3",
                localByteCount: 1000,
                localTitle: "Song",
                localArtist: "Artist",
                localDuration: 120,
                existingName: "Song.mp3",
                existingSize: 1000,
                existingTitle: nil,
                existingArtist: nil,
                existingDuration: nil
            )
        )
    }

    func testMetadataMatchDespiteRename() {
        XCTAssertTrue(
            TrackMatching.isIdentical(
                localFileName: "track-01.mp3",
                localByteCount: 2048,
                localTitle: "Hello",
                localArtist: "Band",
                localDuration: 200,
                existingName: "01 Hello.mp3",
                existingSize: 2048,
                existingTitle: "Hello",
                existingArtist: "Band",
                existingDuration: 199.5
            )
        )
    }

    func testDifferentSizeIsNotIdentical() {
        XCTAssertFalse(
            TrackMatching.isIdentical(
                localFileName: "Song.mp3",
                localByteCount: 1000,
                localTitle: "Song",
                localArtist: "Artist",
                localDuration: 120,
                existingName: "Song.mp3",
                existingSize: 999,
                existingTitle: "Song",
                existingArtist: "Artist",
                existingDuration: 120
            )
        )
    }

    func testTitleDurationSizeWithoutArtist() {
        XCTAssertTrue(
            TrackMatching.isIdentical(
                localFileName: "a.mp3",
                localByteCount: 500,
                localTitle: "Solo",
                localArtist: nil,
                localDuration: 90,
                existingName: "b.mp3",
                existingSize: 500,
                existingTitle: "Solo",
                existingArtist: nil,
                existingDuration: 90.2
            )
        )
    }
}
