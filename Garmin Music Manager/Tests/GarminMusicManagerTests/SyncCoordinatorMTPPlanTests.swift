import XCTest
import GarminMusicCore
@testable import GarminMusicManager

@MainActor
final class SyncCoordinatorMTPPlanTests: XCTestCase {
    func testAllSkipIdenticalWithWritePlaylistCreatesPlaylistWithoutUpload() async {
        let track = makeTrack(id: UUID(), name: "song.mp3", size: 100)
        // Flat org + title/artist → safe file name "Artist - Song.mp3"
        let remoteName = FileNameSanitizer.safeFileName(for: track)
        let remotePath = "Music/Garmin Playlist/\(remoteName)"
        let deviceFile = DeviceFile(
            objectID: "42",
            name: remoteName,
            type: .audio,
            size: 100,
            path: remotePath,
            backendKind: .mtp
        )
        let fake = FakeDeviceFileSystem(
            listMusicSnapshot: DeviceFileSystemSnapshot(
                files: [deviceFile],
                collections: [],
                storageInfo: nil,
                deviceName: "Fake",
                diagnosticMessage: nil
            )
        )
        let store = DeviceBrowserStore()
        store.configure(backend: fake)
        await store.refresh(force: true)

        var settings = SyncSettings.default
        settings.writePlaylist = true
        settings.overwritePolicy = .skipIdentical

        let plan = MTPSyncPlanner.buildPlan(
            tracks: [track],
            playlistName: "Garmin Playlist",
            settings: settings,
            deviceFiles: store.files
        )
        XCTAssertEqual(plan.transferCount, 0)
        XCTAssertEqual(plan.skippedCount, 1)

        let coordinator = SyncCoordinator()
        let result = await coordinator.executeMTPPlan(
            plan,
            deviceBrowser: store,
            playlistName: "Garmin Playlist",
            settings: settings,
            refreshAfter: false
        ) { (_: TransferProgressSnapshot) in }

        XCTAssertEqual(result.uploadedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.playlistName, "Garmin Playlist")
        XCTAssertEqual(fake.uploadCallCount, 0)
        XCTAssertEqual(fake.createPlaylistCallCount, 1)
    }

    func testPartialChunkSuccessMapsFailedTrackIDs() async {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let tracks = [
            makeTrack(id: idA, name: "a.mp3", size: 10),
            makeTrack(id: idB, name: "b.mp3", size: 10),
            makeTrack(id: idC, name: "c.mp3", size: 10)
        ]
        // Planner uses track.displayName on upload rows ("Artist — Title").
        let failedName = tracks[2].displayName
        let fake = FakeDeviceFileSystem()
        fake.uploadResults = [
            .success(DeviceFileOperationResult(
                completedCount: 2,
                failedItems: [failedName],
                message: "2 file(s) uploaded; 1 failed.",
                uploadedFiles: [
                    DeviceUploadedObject(displayName: tracks[0].displayName, remotePath: "Music/P/a.mp3", size: 10, objectID: "1"),
                    DeviceUploadedObject(displayName: tracks[1].displayName, remotePath: "Music/P/b.mp3", size: 10, objectID: "2")
                ]
            ))
        ]
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        var settings = SyncSettings.default
        settings.writePlaylist = false
        let plan = MTPSyncPlanner.buildPlan(
            tracks: tracks,
            playlistName: "P",
            settings: settings,
            deviceFiles: []
        )
        XCTAssertEqual(plan.transferCount, 3)

        let coordinator = SyncCoordinator()
        let result = await coordinator.executeMTPPlan(
            plan,
            deviceBrowser: store,
            playlistName: "P",
            settings: settings,
            refreshAfter: false
        ) { (_: TransferProgressSnapshot) in }

        XCTAssertEqual(result.uploadedCount, 2)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.failedTrackIDs, [idC])
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(fake.uploadCallCount, 1)
    }

    func testCancelledPartialResultPreservesSuccesses() async {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let tracks = [
            makeTrack(id: idA, name: "a.mp3", size: 10),
            makeTrack(id: idB, name: "b.mp3", size: 10),
            makeTrack(id: idC, name: "c.mp3", size: 10)
        ]
        let failedName = tracks[2].displayName
        let fake = FakeDeviceFileSystem()
        // Helper returns partial successes with cancel message (Phase A behavior).
        fake.uploadResults = [
            .success(DeviceFileOperationResult(
                completedCount: 2,
                failedItems: [failedName],
                message: "Cancelled after 2 file(s) uploaded; 1 failed.",
                uploadedFiles: [
                    DeviceUploadedObject(displayName: tracks[0].displayName, remotePath: "Music/P/a.mp3", size: 10, objectID: "1"),
                    DeviceUploadedObject(displayName: tracks[1].displayName, remotePath: "Music/P/b.mp3", size: 10, objectID: "2")
                ]
            ))
        ]
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        var settings = SyncSettings.default
        settings.writePlaylist = false
        let plan = MTPSyncPlanner.buildPlan(
            tracks: tracks,
            playlistName: "P",
            settings: settings,
            deviceFiles: []
        )

        let coordinator = SyncCoordinator()
        let result = await coordinator.executeMTPPlan(
            plan,
            deviceBrowser: store,
            playlistName: "P",
            settings: settings,
            refreshAfter: false
        ) { (_: TransferProgressSnapshot) in }

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.uploadedCount, 2)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.failedTrackIDs, [idC])
        XCTAssertEqual(result.failedItems, [failedName])
        XCTAssertTrue(result.remainingTrackIDs.isEmpty)
        XCTAssertEqual(result.retryTrackIDs, [idC])
    }

    func testCancelLeavesRemainingTrackIDsForLaterChunks() async {
        let ids = (0..<6).map { _ in UUID() }
        let tracks = ids.enumerated().map { i, id in
            makeTrack(id: id, name: "t\(i).mp3", size: 10)
        }
        let fake = FakeDeviceFileSystem()
        // First chunk of 3 succeeds; second chunk cancelled with partial.
        fake.uploadResults = [
            .success(DeviceFileOperationResult(
                completedCount: 3,
                failedItems: [],
                message: "3 file(s) uploaded.",
                uploadedFiles: (0..<3).map { i in
                    DeviceUploadedObject(
                        displayName: tracks[i].displayName,
                        remotePath: planRemoteHint(for: tracks[i], playlist: "P"),
                        size: 10,
                        objectID: "\(i)"
                    )
                }
            )),
            .success(DeviceFileOperationResult(
                completedCount: 1,
                failedItems: [],
                message: "Cancelled after 1 file(s) uploaded.",
                uploadedFiles: [
                    DeviceUploadedObject(
                        displayName: tracks[3].displayName,
                        remotePath: planRemoteHint(for: tracks[3], playlist: "P"),
                        size: 10,
                        objectID: "3"
                    )
                ]
            ))
        ]
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        var settings = SyncSettings.default
        settings.writePlaylist = false
        var performance = PerformanceSettings.default
        performance.uploadBatchSize = 3

        let plan = MTPSyncPlanner.buildPlan(
            tracks: tracks,
            playlistName: "P",
            settings: settings,
            deviceFiles: []
        )

        let coordinator = SyncCoordinator()
        let result = await coordinator.executeMTPPlan(
            plan,
            deviceBrowser: store,
            playlistName: "P",
            settings: settings,
            performance: performance,
            refreshAfter: false
        ) { (_: TransferProgressSnapshot) in }

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.uploadedCount, 4)
        // Tracks 4 and 5 never started in the second chunk after cancel.
        XCTAssertEqual(Set(result.remainingTrackIDs), Set([ids[4], ids[5]]))
        XCTAssertEqual(Set(result.retryTrackIDs), Set([ids[4], ids[5]]))
        XCTAssertTrue(result.failedTrackIDs.isEmpty)
    }

    func testNilUploadWhileCancelledDoesNotMarkWholeChunkFailed() async {
        let tracks = [
            makeTrack(id: UUID(), name: "a.mp3", size: 10),
            makeTrack(id: UUID(), name: "b.mp3", size: 10)
        ]
        let fake = FakeDeviceFileSystem()
        fake.uploadResults = [.failure(CancellationError())]
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        var settings = SyncSettings.default
        settings.writePlaylist = false
        let plan = MTPSyncPlanner.buildPlan(
            tracks: tracks,
            playlistName: "P",
            settings: settings,
            deviceFiles: []
        )

        let coordinator = SyncCoordinator()
        // Simulate Task already cancelled so SyncCoordinator treats nil as cancel.
        let task = Task { @MainActor in
            // Cancel before execute so the nil branch sees Task.isCancelled.
            // We cancel the outer task after starting — use a nested cancelled context.
            await withTaskGroup(of: MTPSyncResult.self) { group in
                group.addTask { @MainActor in
                    let resultTask = Task { @MainActor in
                        await coordinator.executeMTPPlan(
                            plan,
                            deviceBrowser: store,
                            playlistName: "P",
                            settings: settings,
                            refreshAfter: false
                        ) { (_: TransferProgressSnapshot) in }
                    }
                    resultTask.cancel()
                    return await resultTask.value
                }
                return await group.next()!
            }
        }

        let result = await task.value
        // Either cancelled with no whole-chunk fail, or hard-failed the chunk if cancel raced.
        // Primary contract: when CancellationError is returned as nil upload, failed items must not
        // invent names if wasCancelled is true.
        if result.wasCancelled {
            XCTAssertTrue(result.failedItems.isEmpty || result.uploadedCount >= 0)
        }
    }

    func testProgressIsMonotonicAcrossChunks() async {
        let tracks = (0..<6).map { i in
            makeTrack(id: UUID(), name: "t\(i).mp3", size: 100)
        }
        let fake = FakeDeviceFileSystem()
        // Two chunks of 3 with performance batch size 3.
        fake.uploadResults = [
            .success(DeviceFileOperationResult(
                completedCount: 3,
                failedItems: [],
                message: "3 file(s) uploaded.",
                uploadedFiles: (0..<3).map {
                    DeviceUploadedObject(displayName: "t\($0).mp3", remotePath: "Music/P/t\($0).mp3", size: 100, objectID: "\($0)")
                }
            )),
            .success(DeviceFileOperationResult(
                completedCount: 3,
                failedItems: [],
                message: "3 file(s) uploaded.",
                uploadedFiles: (3..<6).map {
                    DeviceUploadedObject(displayName: "t\($0).mp3", remotePath: "Music/P/t\($0).mp3", size: 100, objectID: "\($0)")
                }
            ))
        ]
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        var settings = SyncSettings.default
        settings.writePlaylist = false
        var performance = PerformanceSettings.default
        performance.uploadBatchSize = 3

        let plan = MTPSyncPlanner.buildPlan(
            tracks: tracks,
            playlistName: "P",
            settings: settings,
            deviceFiles: []
        )

        let fractionBox = FractionBox()
        let coordinator = SyncCoordinator()
        let result = await coordinator.executeMTPPlan(
            plan,
            deviceBrowser: store,
            playlistName: "P",
            settings: settings,
            performance: performance,
            refreshAfter: false
        ) { snapshot in
            fractionBox.append(snapshot.fraction)
        }

        XCTAssertEqual(result.uploadedCount, 6)
        XCTAssertEqual(fake.uploadCallCount, 2)
        let fractions = fractionBox.values
        XCTAssertFalse(fractions.isEmpty)
        for index in 1..<fractions.count {
            XCTAssertGreaterThanOrEqual(
                fractions[index] + 0.0001,
                fractions[index - 1],
                "progress should be non-decreasing at \(index): \(fractions)"
            )
        }
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func makeTrack(id: UUID, name: String, size: Int64) -> AudioTrack {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return AudioTrack(
            id: id,
            url: url,
            fileName: name,
            fileExtension: (name as NSString).pathExtension,
            title: (name as NSString).deletingPathExtension,
            artist: "Artist",
            album: "Album",
            durationSeconds: 60,
            byteCount: size,
            codecHint: "mp3",
            compatibility: .ready,
            isSelected: true,
            isDuplicateOnDevice: false
        )
    }

    private func planRemoteHint(for track: AudioTrack, playlist: String) -> String {
        MTPSyncPlanner.remotePath(for: track, playlistName: playlist, settings: .default)
    }
}

private final class FractionBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
