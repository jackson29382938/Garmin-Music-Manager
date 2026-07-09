import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

final class MTPPlaylistResolverTests: XCTestCase {
    func testResolvesSkippedAndUploadedTracksByPath() {
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/a.mp3"),
            fileName: "a.mp3",
            fileExtension: "mp3",
            title: "A",
            artist: "Art",
            album: nil,
            durationSeconds: 100,
            byteCount: 1000,
            codecHint: "mp3",
            compatibility: .ready
        )
        let skipped = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/b.mp3"),
            fileName: "b.mp3",
            fileExtension: "mp3",
            title: "B",
            artist: "Art",
            album: nil,
            durationSeconds: 100,
            byteCount: 2000,
            codecHint: "mp3",
            compatibility: .ready
        )
        let failed = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/c.mp3"),
            fileName: "c.mp3",
            fileExtension: "mp3",
            title: "C",
            artist: "Art",
            album: nil,
            durationSeconds: 100,
            byteCount: 3000,
            codecHint: "mp3",
            compatibility: .ready
        )

        let plan = MTPSyncPlan(items: [
            MTPSyncPlanItem(
                track: track,
                action: .copy,
                targetRemotePath: "Music/Mix/a.mp3",
                uploadFile: DeviceUploadFile(localPath: track.url.path, remotePath: "Music/Mix/a.mp3", displayName: track.displayName)
            ),
            MTPSyncPlanItem(
                track: skipped,
                action: .skipIdentical,
                targetRemotePath: "Music/Mix/b.mp3"
            ),
            MTPSyncPlanItem(
                track: failed,
                action: .copy,
                targetRemotePath: "Music/Mix/c.mp3",
                uploadFile: DeviceUploadFile(localPath: failed.url.path, remotePath: "Music/Mix/c.mp3", displayName: failed.displayName)
            )
        ])

        let deviceFiles = [
            DeviceFile(objectID: "10", name: "a.mp3", type: .audio, size: 1000, path: "Music/Mix/a.mp3", backendKind: .mtp),
            DeviceFile(objectID: "11", name: "b.mp3", type: .audio, size: 2000, path: "Music/Mix/b.mp3", backendKind: .mtp),
            DeviceFile(objectID: "12", name: "c.mp3", type: .audio, size: 3000, path: "Music/Mix/c.mp3", backendKind: .mtp)
        ]

        let resolved = MTPPlaylistResolver.playlistTracks(
            plan: plan,
            failedDisplayNames: [failed.displayName],
            deviceFiles: deviceFiles
        )
        XCTAssertEqual(resolved.map(\.objectID), ["10", "11"])
    }

    func testResolvesFromUploadedObjectIDsWithoutDeviceListing() {
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/a.mp3"),
            fileName: "a.mp3",
            fileExtension: "mp3",
            title: "A",
            artist: "Art",
            album: nil,
            durationSeconds: 100,
            byteCount: 1000,
            codecHint: "mp3",
            compatibility: .ready
        )
        let skipped = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/b.mp3"),
            fileName: "b.mp3",
            fileExtension: "mp3",
            title: "B",
            artist: "Art",
            album: nil,
            durationSeconds: 100,
            byteCount: 2000,
            codecHint: "mp3",
            compatibility: .ready
        )

        let plan = MTPSyncPlan(items: [
            MTPSyncPlanItem(
                track: track,
                action: .copy,
                targetRemotePath: "Music/Mix/a.mp3",
                uploadFile: DeviceUploadFile(localPath: track.url.path, remotePath: "Music/Mix/a.mp3", displayName: track.displayName)
            ),
            MTPSyncPlanItem(
                track: skipped,
                action: .skipIdentical,
                targetRemotePath: "Music/Mix/b.mp3"
            )
        ])

        // Only skip-identical track is on the pre-sync listing; new upload comes from helper IDs.
        let preSync = [
            DeviceFile(objectID: "11", name: "b.mp3", type: .audio, size: 2000, path: "Music/Mix/b.mp3", backendKind: .mtp)
        ]
        let uploaded = [
            DeviceUploadedObject(displayName: track.displayName, remotePath: "Music/Mix/a.mp3", size: 1000, objectID: "99")
        ]

        let resolved = MTPPlaylistResolver.playlistTracks(
            plan: plan,
            failedDisplayNames: [],
            deviceFiles: preSync,
            uploadedObjects: uploaded
        )
        XCTAssertEqual(Set(resolved.compactMap(\.objectID)), Set(["99", "11"]))
        XCTAssertTrue(
            MTPPlaylistResolver.canResolveWithoutRefresh(
                plan: plan,
                failedDisplayNames: [],
                deviceFiles: preSync,
                uploadedObjects: uploaded
            )
        )
    }

    func testCannotResolveWithoutRefreshWhenObjectIDsMissing() {
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/a.mp3"),
            fileName: "a.mp3",
            fileExtension: "mp3",
            title: "A",
            artist: "Art",
            album: nil,
            durationSeconds: 100,
            byteCount: 1000,
            codecHint: "mp3",
            compatibility: .ready
        )
        let plan = MTPSyncPlan(items: [
            MTPSyncPlanItem(
                track: track,
                action: .copy,
                targetRemotePath: "Music/Mix/a.mp3",
                uploadFile: DeviceUploadFile(localPath: track.url.path, remotePath: "Music/Mix/a.mp3", displayName: track.displayName)
            )
        ])
        let uploaded = [
            DeviceUploadedObject(displayName: track.displayName, remotePath: "Music/Mix/a.mp3", size: 1000, objectID: nil)
        ]
        XCTAssertFalse(
            MTPPlaylistResolver.canResolveWithoutRefresh(
                plan: plan,
                failedDisplayNames: [],
                deviceFiles: [],
                uploadedObjects: uploaded
            )
        )
    }
}
