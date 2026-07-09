import Foundation
import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

final class LibraryLifecycleSettingsTests: XCTestCase {
    func testLibraryDefaultsAndClamp() {
        var lib = LibrarySettings.default
        XCTAssertTrue(lib.restoreQueueOnLaunch)
        XCTAssertEqual(lib.importSelectionMode, .allReady)
        XCTAssertEqual(lib.largeFileWarningMB, 250)
        lib.durationMatchToleranceSeconds = 99
        lib.importConcurrency = -3
        lib.clamp()
        XCTAssertEqual(lib.durationMatchToleranceSeconds, LibrarySettings.durationToleranceRange.upperBound)
        XCTAssertEqual(lib.importConcurrency, 0)
    }

    func testLifecycleRemoteRootSanitized() {
        var life = LifecycleSettings.default
        life.remoteMusicRoot = " /Music/Extra/ "
        life.clamp()
        XCTAssertEqual(life.remoteMusicRoot, "Music/Extra")
    }

    func testSettingsStoreRoundTripBlobs() {
        let suite = "GarminMusicManagerTests.Lib.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        var lib = LibrarySettings.default
        lib.fastImport = true
        lib.skipDuplicatesWhenSending = true
        lib.storageExceedPolicy = .blockSend
        store.librarySettings = lib

        var conv = ConversionSettings.default
        conv.aacSampleRate = .hz48000
        conv.convertWAV = true
        conv.customFFmpegPath = "/opt/homebrew/bin/ffmpeg"
        store.conversionSettings = conv

        var life = LifecycleSettings.default
        life.releaseHelperAfterSend = true
        life.playlistWriteStrategy = .alwaysCreateNew
        store.lifecycleSettings = life

        XCTAssertTrue(store.librarySettings.fastImport)
        XCTAssertTrue(store.librarySettings.skipDuplicatesWhenSending)
        XCTAssertEqual(store.librarySettings.storageExceedPolicy, .blockSend)
        XCTAssertEqual(store.conversionSettings.aacSampleRate, .hz48000)
        XCTAssertTrue(store.conversionSettings.convertWAV)
        XCTAssertTrue(store.lifecycleSettings.releaseHelperAfterSend)
        XCTAssertEqual(store.lifecycleSettings.playlistWriteStrategy, .alwaysCreateNew)
    }

    @MainActor
    func testSyncableTracksSkipsDuplicatesWhenEnabled() {
        let session = MacLibrarySession()
        let ready = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/a.mp3"),
            fileName: "a.mp3",
            fileExtension: "mp3",
            title: "A",
            artist: nil,
            album: nil,
            durationSeconds: nil,
            byteCount: 1,
            codecHint: "mp3",
            compatibility: .ready,
            isSelected: true,
            isDuplicateOnDevice: true
        )
        let unique = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/b.mp3"),
            fileName: "b.mp3",
            fileExtension: "mp3",
            title: "B",
            artist: nil,
            album: nil,
            durationSeconds: nil,
            byteCount: 1,
            codecHint: "mp3",
            compatibility: .ready,
            isSelected: true,
            isDuplicateOnDevice: false
        )
        let all = session.syncableTracks(from: [ready, unique], skipDuplicates: false)
        let filtered = session.syncableTracks(from: [ready, unique], skipDuplicates: true)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.fileName, "b.mp3")
    }

    func testTrackMatchingNameAndSizeModeIgnoresMetadataOnly() {
        TrackMatching.matchMode = .nameAndSize
        defer { TrackMatching.matchMode = .smart }
        let match = TrackMatching.isIdentical(
            localFileName: "song.mp3",
            localByteCount: 1000,
            localTitle: "Song",
            localArtist: "Artist",
            localDuration: 120,
            existingName: "renamed.mp3",
            existingSize: 1000,
            existingTitle: "Song",
            existingArtist: "Artist",
            existingDuration: 120
        )
        XCTAssertFalse(match, "nameAndSize should not match metadata-only rename")
    }
}
