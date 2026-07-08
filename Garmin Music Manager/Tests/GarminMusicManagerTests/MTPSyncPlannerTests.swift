import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

final class MTPSyncPlannerTests: XCTestCase {
    func testSkipIdenticalWhenNameAndSizeMatch() {
        let track = makeTrack(name: "Artist - Song.mp3", byteCount: 4_000_000)
        let deviceFile = DeviceFile(
            objectID: "42",
            name: "Artist - Song.mp3",
            type: .audio,
            size: 4_000_000,
            parentID: nil,
            path: "Music/Garmin Playlist/Artist - Song.mp3",
            backendKind: .mtp
        )

        let plan = MTPSyncPlanner.buildPlan(
            tracks: [track],
            playlistName: "Garmin Playlist",
            settings: SyncSettings.default,
            deviceFiles: [deviceFile]
        )

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].action, .skipIdentical)
        XCTAssertTrue(plan.uploads.isEmpty)
        XCTAssertEqual(plan.skippedCount, 1)
    }

    func testReplaceWhenSamePathDifferentSize() {
        let track = makeTrack(name: "Artist - Song.mp3", byteCount: 5_000_000)
        let deviceFile = DeviceFile(
            objectID: "42",
            name: "Artist - Song.mp3",
            type: .audio,
            size: 4_000_000,
            parentID: nil,
            path: "Music/Garmin Playlist/Artist - Song.mp3",
            backendKind: .mtp
        )

        let plan = MTPSyncPlanner.buildPlan(
            tracks: [track],
            playlistName: "Garmin Playlist",
            settings: SyncSettings.default,
            deviceFiles: [deviceFile]
        )

        XCTAssertEqual(plan.items[0].action, .replace)
        XCTAssertEqual(plan.deletions.count, 1)
        XCTAssertEqual(plan.uploads.count, 1)
        XCTAssertEqual(plan.uploads[0].replaceObjectID, "42", "replace uploads must carry the old object's ID so the helper deletes it just before uploading")
    }

    func testCopyAndKeepBothCarryNoReplaceObjectID() {
        var settings = SyncSettings.default
        settings.overwritePolicy = .keepBoth

        let newTrack = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/Newcomer - Fresh.mp3"),
            fileName: "Newcomer - Fresh.mp3",
            fileExtension: "mp3",
            title: "Fresh",
            artist: "Newcomer",
            album: nil,
            durationSeconds: 180,
            byteCount: 2_000_000,
            codecHint: "mp3",
            compatibility: .ready
        )
        let conflictingTrack = makeTrack(name: "Artist - Song.mp3", byteCount: 4_000_000)
        let deviceFile = DeviceFile(
            objectID: "42",
            name: "Artist - Song.mp3",
            type: .audio,
            size: 4_000_000,
            parentID: nil,
            path: "Music/Garmin Playlist/Artist - Song.mp3",
            backendKind: .mtp
        )

        let plan = MTPSyncPlanner.buildPlan(
            tracks: [newTrack, conflictingTrack],
            playlistName: "Garmin Playlist",
            settings: settings,
            deviceFiles: [deviceFile]
        )

        XCTAssertEqual(plan.items.map(\.action), [.copy, .keepBoth])
        XCTAssertEqual(plan.uploads.count, 2)
        XCTAssertTrue(plan.uploads.allSatisfy { $0.replaceObjectID == nil })
    }

    func testKeepBothCreatesUniqueRemotePath() {
        var settings = SyncSettings.default
        settings.overwritePolicy = .keepBoth

        let track = makeTrack(name: "Artist - Song.mp3", byteCount: 4_000_000)
        let deviceFile = DeviceFile(
            objectID: "42",
            name: "Artist - Song.mp3",
            type: .audio,
            size: 4_000_000,
            parentID: nil,
            path: "Music/Garmin Playlist/Artist - Song.mp3",
            backendKind: .mtp
        )

        let plan = MTPSyncPlanner.buildPlan(
            tracks: [track],
            playlistName: "Garmin Playlist",
            settings: settings,
            deviceFiles: [deviceFile]
        )

        XCTAssertEqual(plan.items[0].action, .keepBoth)
        XCTAssertNotEqual(plan.items[0].targetRemotePath, "Music/Garmin Playlist/Artist - Song.mp3")
        XCTAssertTrue(plan.items[0].targetRemotePath.contains("Artist - Song 2"))
    }

    func testArtistOrganizationAddsFolderToRemotePath() {
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/Artist - Song.mp3"),
            fileName: "Artist - Song.mp3",
            fileExtension: "mp3",
            title: "Song",
            artist: "Artist",
            album: "Album",
            durationSeconds: 200,
            byteCount: 3_000_000,
            codecHint: "mp3",
            compatibility: .ready
        )

        let path = MTPSyncPlanner.remotePath(
            for: track,
            playlistName: "Run Mix",
            settings: SyncSettings(overwritePolicy: .replace, organizationPolicy: .byArtist, writePlaylist: false, convertIncompatibleFormats: false)
        )

        XCTAssertEqual(path, "Music/Run Mix/Artist/Artist - Song.mp3")
    }

    func testDuplicateLocalNamesReserveUniqueRemotePaths() {
        let first = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/source-a/Song.mp3"),
            fileName: "Song.mp3",
            fileExtension: "mp3",
            title: "Song",
            artist: nil,
            album: nil,
            durationSeconds: 200,
            byteCount: 3_000_000,
            codecHint: "mp3",
            compatibility: .ready
        )
        let second = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/source-b/Song.mp3"),
            fileName: "Song.mp3",
            fileExtension: "mp3",
            title: "Song",
            artist: nil,
            album: nil,
            durationSeconds: 200,
            byteCount: 3_000_000,
            codecHint: "mp3",
            compatibility: .ready
        )

        let plan = MTPSyncPlanner.buildPlan(
            tracks: [first, second],
            playlistName: "Run Mix",
            settings: SyncSettings.default,
            deviceFiles: []
        )

        XCTAssertEqual(plan.uploads.map(\.remotePath), [
            "Music/Run Mix/Song.mp3",
            "Music/Run Mix/Song 2.mp3"
        ])
    }

    private func makeTrack(name: String, byteCount: Int64) -> AudioTrack {
        AudioTrack(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            fileName: name,
            fileExtension: "mp3",
            title: "Song",
            artist: "Artist",
            album: nil,
            durationSeconds: 200,
            byteCount: byteCount,
            codecHint: "mp3",
            compatibility: .ready
        )
    }
}
