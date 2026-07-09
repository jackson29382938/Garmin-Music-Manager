import XCTest
@testable import GarminMusicManager

final class MTPSyncResultTests: XCTestCase {
    func testDefaultInitLeavesCancelFalseAndEmptyFailures() {
        let result = MTPSyncResult(
            uploadedCount: 2,
            skippedCount: 1,
            replacedCount: 0,
            failedCount: 0
        )
        XCTAssertFalse(result.wasCancelled)
        XCTAssertNil(result.playlistName)
        XCTAssertTrue(result.failedItems.isEmpty)
    }

    func testCancelledResultPreservesPartialCounts() {
        let result = MTPSyncResult(
            uploadedCount: 3,
            skippedCount: 2,
            replacedCount: 1,
            failedCount: 1,
            wasCancelled: true,
            playlistName: nil,
            failedItems: ["bad.mp3"]
        )
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.uploadedCount, 3)
        XCTAssertEqual(result.failedItems, ["bad.mp3"])
        XCTAssertNil(result.playlistName)
    }

    func testRetryTrackIDsMergesFailedAndRemaining() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let result = MTPSyncResult(
            uploadedCount: 1,
            skippedCount: 0,
            replacedCount: 0,
            failedCount: 1,
            wasCancelled: true,
            failedTrackIDs: [a, b],
            remainingTrackIDs: [b, c]
        )
        XCTAssertEqual(result.retryTrackIDs, [a, b, c])
        XCTAssertTrue(result.canRetryFailed)
    }
}

final class TrackPreparationResultTests: XCTestCase {
    func testHasConversionIssues() {
        let clean = TrackPreparationResult(tracks: [], conversionFailures: [], convertedCount: 0)
        XCTAssertFalse(clean.hasConversionIssues)

        let dirty = TrackPreparationResult(
            tracks: [],
            conversionFailures: ["Cannot convert x.flac: ffmpeg is not installed"],
            convertedCount: 0
        )
        XCTAssertTrue(dirty.hasConversionIssues)
    }
}
