import XCTest
@testable import GarminMusicManager

final class TransferCompletionNoticeTests: XCTestCase {
    func testMTPFullSuccessOffersShowOnWatch() {
        let notice = TransferCompletionNotice.forMTP(
            MTPSyncResult(
                uploadedCount: 3,
                skippedCount: 1,
                replacedCount: 0,
                failedCount: 0,
                playlistName: "Run",
                failedTrackIDs: []
            ),
            canRetry: false
        )
        XCTAssertEqual(notice.kind, .success)
        XCTAssertEqual(notice.title, "Send complete")
        XCTAssertEqual(notice.action, .showOnWatch)
        XCTAssertTrue(notice.message?.contains("sent 3") == true)
        XCTAssertTrue(notice.message?.contains("playlist") == true)
    }

    func testMTPAllSkippedOffersShowOnWatch() {
        let notice = TransferCompletionNotice.forMTP(
            MTPSyncResult(
                uploadedCount: 0,
                skippedCount: 5,
                replacedCount: 0,
                failedCount: 0,
                failedTrackIDs: []
            ),
            canRetry: false
        )
        XCTAssertEqual(notice.kind, .success)
        XCTAssertEqual(notice.title, "Already on watch")
        XCTAssertEqual(notice.action, .showOnWatch)
    }

    func testMTPPartialFailureOffersRetryWhenAllowed() {
        let id = UUID()
        let notice = TransferCompletionNotice.forMTP(
            MTPSyncResult(
                uploadedCount: 2,
                skippedCount: 0,
                replacedCount: 0,
                failedCount: 1,
                failedTrackIDs: [id]
            ),
            canRetry: true
        )
        XCTAssertEqual(notice.kind, .warning)
        XCTAssertEqual(notice.title, "Partially sent")
        XCTAssertEqual(notice.action, .retryFailed)
        XCTAssertEqual(notice.actionTitle, "Retry / continue")
    }

    func testMTPCancelWithUploadsOffersShowOnWatchWhenNoRetry() {
        let notice = TransferCompletionNotice.forMTP(
            MTPSyncResult(
                uploadedCount: 2,
                skippedCount: 0,
                replacedCount: 0,
                failedCount: 0,
                wasCancelled: true,
                failedTrackIDs: []
            ),
            canRetry: false
        )
        XCTAssertEqual(notice.kind, .warning)
        XCTAssertEqual(notice.title, "Send cancelled")
        XCTAssertEqual(notice.action, .showOnWatch)
    }

    func testMTPCancelBeforeUploadIsInfo() {
        let notice = TransferCompletionNotice.forMTP(
            MTPSyncResult(
                uploadedCount: 0,
                skippedCount: 0,
                replacedCount: 0,
                failedCount: 0,
                wasCancelled: true
            ),
            canRetry: false
        )
        XCTAssertEqual(notice.kind, .info)
        XCTAssertEqual(notice.title, "Send cancelled")
        XCTAssertNil(notice.action)
    }

    func testMountedSuccessIncludesCountsAndShowOnWatch() {
        let folder = URL(fileURLWithPath: "/tmp/Music/Playlist", isDirectory: true)
        let playlist = folder.appendingPathComponent("Playlist.m3u8")
        let notice = TransferCompletionNotice.forMounted(
            SyncResult(
                copiedCount: 4,
                skippedCount: 1,
                replacedCount: 0,
                playlistURL: playlist,
                targetFolder: folder
            )
        )
        XCTAssertEqual(notice.kind, .success)
        XCTAssertEqual(notice.action, .showOnWatch)
        XCTAssertTrue(notice.message?.contains("copied 4") == true)
    }

    func testFailedAndCancelledHelpers() {
        XCTAssertEqual(TransferCompletionNotice.cancelled().kind, .info)
        let failed = TransferCompletionNotice.failed("boom")
        XCTAssertEqual(failed.kind, .error)
        XCTAssertEqual(failed.title, "Send failed")
        XCTAssertEqual(failed.message, "boom")
    }
}
