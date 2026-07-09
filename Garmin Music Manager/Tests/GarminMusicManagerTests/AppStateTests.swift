import Foundation
import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

final class SettingsStoreAppStateTests: XCTestCase {
    func testDestinationModeDefaultsToAutoAndPersistsCustomFolder() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.destinationMode, .autoDetected)

        let folder = URL(fileURLWithPath: "/tmp/Garmin/Music", isDirectory: true)
        store.destinationMode = .customFolder
        store.saveDestination(folder)

        XCTAssertEqual(store.destinationMode, .customFolder)
        XCTAssertEqual(store.lastDestinationURL?.path, folder.path)
    }

    func testResetAppStateForgetsDestinationWithoutResettingSyncPreferences() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = SettingsStore(defaults: defaults)

        store.destinationMode = .customFolder
        store.saveDestination(URL(fileURLWithPath: "/tmp/Mistake/Music", isDirectory: true))
        store.playlistName = "Keep This"
        store.syncSettings = SyncSettings(
            overwritePolicy: .replace,
            organizationPolicy: .byArtist,
            writePlaylist: false,
            convertIncompatibleFormats: true
        )

        store.resetAppState()

        XCTAssertEqual(store.destinationMode, .autoDetected)
        XCTAssertNil(store.lastDestinationURL)
        XCTAssertEqual(store.playlistName, "Keep This")
        XCTAssertEqual(store.syncSettings.organizationPolicy, .byArtist)
        XCTAssertFalse(store.syncSettings.writePlaylist)
    }

    func testAlwaysPreviewBeforeSendDefaultsToTrueAndPersists() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.alwaysPreviewBeforeSend)

        store.alwaysPreviewBeforeSend = false
        XCTAssertFalse(store.alwaysPreviewBeforeSend)

        let store2 = SettingsStore(defaults: defaults)
        XCTAssertFalse(store2.alwaysPreviewBeforeSend)
    }
}

final class GarminFolderTargetTests: XCTestCase {
    func testMountedMusicRootDropsDuplicateMusicComponent() {
        let root = URL(fileURLWithPath: "/Volumes/GARMIN/Music", isDirectory: true)
        let target = GarminFolderTarget("Music/Run Mix")

        XCTAssertEqual(target.destinationURL(relativeTo: root).path, "/Volumes/GARMIN/Music/Run Mix")
    }

    func testRemotePathSanitizesFileNameUnderTargetFolder() {
        let target = GarminFolderTarget("Music/Run:Mix?")

        XCTAssertEqual(target.storagePath, "Music/Run-Mix-")
        XCTAssertEqual(target.remotePath(for: "Song/Name?.mp3"), "Music/Run-Mix-/Song-Name-.mp3")
    }
}

@MainActor
final class AppModelPlaylistAndResetTests: XCTestCase {
    func testAppleMusicPlaylistPreparationReplacesQueuePreservesOrderAndSetsPlaylistName() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = folder.appendingPathComponent("01 First.mp3")
        let second = folder.appendingPathComponent("02 Second.mp3")
        FileManager.default.createFile(atPath: first.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: second.path, contents: Data([0x02]))

        let model = AppModel(settingsStore: SettingsStore(defaults: defaults), autoRefresh: false)
        model.musicLibrary = MusicLibrarySnapshot(
            tracksByID: [
                "first": LibraryTrack(id: "first", title: "First", artist: "Artist", album: "Album", location: first, isCloudOnly: false, isDRMProtected: false, fileExtension: "mp3"),
                "cloud": LibraryTrack(id: "cloud", title: "Cloud", artist: "Artist", album: "Album", location: nil, isCloudOnly: true, isDRMProtected: false, fileExtension: nil),
                "second": LibraryTrack(id: "second", title: "Second", artist: "Artist", album: "Album", location: second, isCloudOnly: false, isDRMProtected: false, fileExtension: "mp3")
            ],
            playlists: [
                LibraryPlaylist(id: "playlist", name: "Long Run", trackIDs: ["first", "cloud", "second"])
            ],
            albums: []
        )

        await model.prepareAppleMusicPlaylistForSyncNow("playlist")

        XCTAssertEqual(model.playlistName, "Long Run")
        XCTAssertEqual(model.tracks.map(\.url), [first, second])
        XCTAssertTrue(model.tracks.allSatisfy(\.isSelected))
    }

    func testResetAppStateClearsAppOwnedStateAndTemporaryConversions() throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = SettingsStore(defaults: defaults)
        let customDestination = URL(fileURLWithPath: "/tmp/MacMusicMistake", isDirectory: true)
        store.destinationMode = .customFolder
        store.saveDestination(customDestination)
        store.playlistName = "Saved Playlist"

        let conversionFolder = AudioConverter.temporaryConversionDirectory
        try FileManager.default.createDirectory(at: conversionFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: conversionFolder.appendingPathComponent("converted.m4a").path,
            contents: Data([0x01])
        )

        let model = AppModel(settingsStore: store, autoRefresh: false)
        model.searchText = "needle"
        model.tracks = [
            AudioTrack(
                url: URL(fileURLWithPath: "/tmp/song.mp3"),
                fileName: "song.mp3",
                fileExtension: "mp3",
                title: "Song",
                artist: "Artist",
                album: nil,
                durationSeconds: nil,
                byteCount: 1,
                codecHint: nil,
                compatibility: .ready
            )
        ]
        model.musicLibraryStatus = .loaded(playlistCount: 1, albumCount: 1, trackCount: 1)

        model.resetAppState()

        XCTAssertEqual(model.destinationMode, .autoDetected)
        XCTAssertNil(model.destinationOverride)
        XCTAssertNil(model.activeDestination)
        XCTAssertTrue(model.tracks.isEmpty)
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.playlistName, "Saved Playlist")
        XCTAssertEqual(store.destinationMode, .autoDetected)
        XCTAssertNil(store.lastDestinationURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: conversionFolder.path))
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "GarminMusicManagerTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Could not create isolated UserDefaults suite.")
    }
    defaults.set(suiteName, forKey: "__suiteName")
    return defaults
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "__suiteName") ?? ""
}
