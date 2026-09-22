import Foundation
import XCTest
@testable import GarminMusicManager

final class DropValidatorTests: XCTestCase {
    func testRejectsEmptyAndBusy() {
        var ctx = DropEvaluationContext.idle
        ctx.isBusy = true
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 1,
            displayNames: ["a.mp3"]
        )
        XCTAssertEqual(
            DropValidator.validate(items: .empty, destination: .deviceMusicRoot, context: .idle),
            .rejected("Nothing to drop")
        )
        XCTAssertEqual(
            DropValidator.validate(items: items, destination: .deviceMusicRoot, context: ctx),
            .rejected("Busy — wait for the current operation")
        )
    }

    func testRejectsWatchWhenDisconnected() {
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 100,
            displayNames: ["a.mp3"]
        )
        XCTAssertEqual(
            DropValidator.validate(items: items, destination: .deviceMusicRoot, context: .idle),
            .rejected("Watch not connected")
        )
    }

    func testAcceptsLocalToWatchWhenConfigured() {
        var ctx = DropEvaluationContext.idle
        ctx.deviceConfigured = true
        ctx.availableCapacity = 1_000_000
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 100,
            displayNames: ["a.mp3"]
        )
        XCTAssertNil(DropValidator.validate(items: items, destination: .deviceMusicRoot, context: ctx))
        XCTAssertTrue(DropValidator.isAcceptable(items: items, destination: .deviceMusicRoot, context: ctx))
    }

    func testBlocksWhenStorageExceedsAndPolicyBlocks() {
        var ctx = DropEvaluationContext.idle
        ctx.deviceConfigured = true
        ctx.availableCapacity = 50
        ctx.storageExceedPolicy = .blockSend
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 100,
            displayNames: ["a.mp3"]
        )
        XCTAssertEqual(
            DropValidator.validate(items: items, destination: .deviceMusicRoot, context: ctx),
            .rejected("Not enough free space on the watch")
        )
    }

    func testRejectsSameLocalFolder() {
        var ctx = DropEvaluationContext.idle
        ctx.isSameLocalFolder = true
        let folder = URL(fileURLWithPath: "/tmp/Music")
        let items = DragItemSet(
            localURLs: [folder.appendingPathComponent("a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 1,
            displayNames: ["a.mp3"]
        )
        XCTAssertEqual(
            DropValidator.validate(items: items, destination: .localFolder(folder), context: ctx),
            .rejected("Same folder")
        )
    }
}

final class DropOperationResolverTests: XCTestCase {
    private var connected: DropEvaluationContext {
        var ctx = DropEvaluationContext.idle
        ctx.deviceConfigured = true
        ctx.availableCapacity = 10_000_000
        ctx.sameVolumeAsDestination = true
        return ctx
    }

    func testLocalToWatchDefaultsToTransferCopy() {
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 10,
            displayNames: ["a.mp3"]
        )
        XCTAssertEqual(
            DropOperationResolver.resolve(
                items: items,
                destination: .deviceMusicRoot,
                modifiers: .none,
                context: connected
            ),
            .transferCopy
        )
    }

    func testCommandForcesTransferMoveToWatch() {
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 10,
            displayNames: ["a.mp3"]
        )
        XCTAssertEqual(
            DropOperationResolver.resolve(
                items: items,
                destination: .deviceMusicRoot,
                modifiers: .command,
                context: connected
            ),
            .transferMove
        )
    }

    func testOptionForcesLocalCopyEvenOnSameVolume() {
        var ctx = connected
        ctx.sameVolumeAsDestination = true
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 10,
            displayNames: ["a.mp3"]
        )
        XCTAssertEqual(
            DropOperationResolver.resolve(
                items: items,
                destination: .localFolder(URL(fileURLWithPath: "/tmp/dest")),
                modifiers: .option,
                context: ctx
            ),
            .copy
        )
    }

    func testLocalToLocalDefaultsToMoveEvenAcrossVolumes() {
        var ctx = connected
        ctx.sameVolumeAsDestination = false
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 10,
            displayNames: ["a.mp3"]
        )
        XCTAssertEqual(
            DropOperationResolver.resolve(
                items: items,
                destination: .localFolder(URL(fileURLWithPath: "/Volumes/Other/Music")),
                modifiers: .none,
                context: ctx
            ),
            .move
        )
    }

    func testWatchToWatchPlaylistIsMove() {
        let items = DragItemSet(
            localURLs: [],
            deviceFileIDs: ["mtp:1"],
            sourceKind: .device,
            totalByteCount: 10,
            displayNames: ["song.mp3"]
        )
        XCTAssertEqual(
            DropOperationResolver.resolve(
                items: items,
                destination: .devicePlaylistFolder(name: "Run"),
                modifiers: .none,
                context: connected
            ),
            .move
        )
        XCTAssertEqual(
            DropOperation.move.dropOverlayLabel(for: .devicePlaylistFolder(name: "Run")),
            "Move to playlist"
        )
    }

    func testWatchToLocalOverlaySaysCopyToMac() {
        XCTAssertEqual(
            DropOperation.transferCopy.dropOverlayLabel(for: .localFolder(URL(fileURLWithPath: "/tmp/Music"))),
            "Copy to Mac"
        )
    }
}

final class DropConfirmPolicyTests: XCTestCase {
    func testConfirmsDestructiveMove() {
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 10,
            displayNames: ["a.mp3"]
        )
        XCTAssertTrue(
            DropConfirmPolicy.shouldConfirm(items: items, operation: .transferMove, context: .idle)
        )
        XCTAssertFalse(
            DropConfirmPolicy.shouldConfirm(items: items, operation: .transferCopy, context: .idle)
        )
    }

    func testConfirmsLargeSelection() {
        let urls = (0..<DropConfirmPolicy.largeFileCountThreshold).map {
            URL(fileURLWithPath: "/tmp/f\($0).mp3")
        }
        let items = DragItemSet(
            localURLs: urls,
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 10,
            displayNames: urls.map(\.lastPathComponent)
        )
        XCTAssertTrue(
            DropConfirmPolicy.shouldConfirm(items: items, operation: .transferCopy, context: .idle)
        )
    }

    func testConfirmsReplaceCollisions() {
        var ctx = DropEvaluationContext.idle
        ctx.hasNameCollisions = true
        ctx.overwritePolicy = .replace
        let items = DragItemSet(
            localURLs: [URL(fileURLWithPath: "/tmp/a.mp3")],
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: 10,
            displayNames: ["a.mp3"]
        )
        XCTAssertTrue(
            DropConfirmPolicy.shouldConfirm(items: items, operation: .transferCopy, context: ctx)
        )
    }
}
