import XCTest
@testable import GarminMusicManager

final class SendPreviewPolicyTests: XCTestCase {
    private func track(name: String = "a.mp3") -> AudioTrack {
        AudioTrack(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            fileName: name,
            fileExtension: "mp3",
            title: name,
            artist: nil,
            album: nil,
            durationSeconds: nil,
            byteCount: 100,
            codecHint: nil,
            compatibility: .ready
        )
    }

    private func preview(actions: [SyncPreviewItem.SyncAction]) -> SyncPreview {
        let items = actions.map { action in
            SyncPreviewItem(track: track(), action: action, targetPath: "Music/\(track().fileName)")
        }
        return SyncPreview(items: items, totalBytesToCopy: 100)
    }

    func testAlwaysPreviewForcesSheet() {
        let p = preview(actions: [.copy])
        XCTAssertTrue(SendPreviewPolicy.shouldShowPreview(
            alwaysPreview: true,
            exceedsAvailableStorage: false,
            preview: p
        ))
    }

    func testStorageExceedForcesSheet() {
        let p = preview(actions: [.copy])
        XCTAssertTrue(SendPreviewPolicy.shouldShowPreview(
            alwaysPreview: false,
            exceedsAvailableStorage: true,
            preview: p
        ))
    }

    func testReplaceForcesSheet() {
        let p = preview(actions: [.replace, .copy])
        XCTAssertTrue(SendPreviewPolicy.shouldShowPreview(
            alwaysPreview: false,
            exceedsAvailableStorage: false,
            preview: p
        ))
    }

    func testKeepBothForcesSheet() {
        let p = preview(actions: [.keepBoth])
        XCTAssertTrue(SendPreviewPolicy.shouldShowPreview(
            alwaysPreview: false,
            exceedsAvailableStorage: false,
            preview: p
        ))
    }

    func testCopyOnlyWithoutPreferenceSkipsSheet() {
        let p = preview(actions: [.copy, .skipIdentical])
        XCTAssertFalse(SendPreviewPolicy.shouldShowPreview(
            alwaysPreview: false,
            exceedsAvailableStorage: false,
            preview: p
        ))
    }
}

final class TransferProgressSnapshotLabelTests: XCTestCase {
    func testItemLabelAndPrimaryLine() {
        let snap = TransferProgressSnapshot(
            fraction: 0.5,
            message: "Uploading",
            itemIndex: 1,
            itemCount: 4,
            itemName: "Run.mp3"
        )
        XCTAssertEqual(snap.itemLabel, "2 of 4 · Run.mp3")
        XCTAssertEqual(snap.primaryLine, "2 of 4 · Run.mp3")
        XCTAssertEqual(snap.percentLabel, "50%")
    }

    func testPhaseOnlyUsesMessage() {
        let snap = TransferProgressSnapshot.phase(0.1, "Preparing…")
        XCTAssertNil(snap.itemLabel)
        XCTAssertEqual(snap.primaryLine, "Preparing…")
    }
}

final class UserNoticeCodeTests: XCTestCase {
    func testDeviceBusyHasStableCode() {
        let notice = TransferCompletionNotice.deviceBusy()
        XCTAssertEqual(notice.code, .deviceBusy)
        XCTAssertEqual(notice.kind, .warning)
    }

    func testActionTitles() {
        XCTAssertEqual(
            UserNotice(kind: .success, title: "x", action: .showOnWatch).actionTitle,
            "View on Watch"
        )
        XCTAssertEqual(
            UserNotice(kind: .warning, title: "x", action: .retryFailed).actionTitle,
            "Retry / continue"
        )
    }
}
