import Foundation
import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

@MainActor
final class MacLibrarySessionTests: XCTestCase {
    func testFilteredTracksMatchesArtistTitleAndFilename() {
        let session = MacLibrarySession()
        let tracks = [
            makeTrack(fileName: "a.mp3", title: "Hello", artist: "Artist A"),
            makeTrack(fileName: "night.mp3", title: "Night Run", artist: "B")
        ]
        XCTAssertEqual(session.filteredTracks(from: tracks, searchText: "night").map(\.fileName), ["night.mp3"])
        XCTAssertEqual(session.filteredTracks(from: tracks, searchText: "artist a").count, 1)
        XCTAssertEqual(session.filteredTracks(from: tracks, searchText: "").count, 2)
    }

    func testSelectAllReadyOnlySelectsCopyable() {
        let session = MacLibrarySession()
        let ready = makeTrack(fileName: "ok.mp3", title: "OK", artist: nil, canCopy: true)
        let blocked = makeTrack(fileName: "bad.flac", title: "Bad", artist: nil, canCopy: false)
        let result = session.selectAllReady(in: [ready, blocked])
        XCTAssertTrue(result[0].isSelected)
        XCTAssertFalse(result[1].isSelected)
    }

    func testSelectOnlyAppliesRetryIDs() {
        let session = MacLibrarySession()
        var a = makeTrack(fileName: "a.mp3", title: "A", artist: nil)
        var b = makeTrack(fileName: "b.mp3", title: "B", artist: nil)
        a.isSelected = true
        b.isSelected = true
        let result = session.selectOnly(ids: [a.id], in: [a, b])
        XCTAssertTrue(result[0].isSelected)
        XCTAssertFalse(result[1].isSelected)
    }

    func testRemoveTracksUsesFilteredOffsets() {
        let session = MacLibrarySession()
        let a = makeTrack(fileName: "a.mp3", title: "Alpha", artist: nil)
        let b = makeTrack(fileName: "b.mp3", title: "Beta", artist: nil)
        let c = makeTrack(fileName: "c.mp3", title: "Alpha Two", artist: nil)
        let all = [a, b, c]
        let filtered = session.filteredTracks(from: all, searchText: "alpha")
        // Remove first filtered (a)
        let remaining = session.removeTracks(at: IndexSet(integer: 0), filtered: filtered, from: all)
        XCTAssertEqual(remaining.map(\.fileName), ["b.mp3", "c.mp3"])
    }

    func testPlanImportSkipsEmptySelection() {
        let session = MacLibrarySession()
        let library = MusicLibrarySnapshot(
            tracksByID: [
                "cloud": LibraryTrack(
                    id: "cloud",
                    title: "Cloud",
                    artist: "A",
                    album: "B",
                    location: nil,
                    isCloudOnly: true,
                    isDRMProtected: false,
                    fileExtension: nil
                )
            ],
            playlists: [],
            albums: []
        )
        let plan = session.planImportLibraryTracks(trackIDs: ["cloud"], musicLibrary: library)
        XCTAssertTrue(plan.urls.isEmpty)
        XCTAssertFalse(plan.closeBrowser)
        XCTAssertFalse(plan.logMessages.isEmpty)
    }

    func testPlanAppleMusicPlaylistSetsNameAndReplace() throws {
        let session = MacLibrarySession()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("t.mp3")
        FileManager.default.createFile(atPath: file.path, contents: Data([0x01]))

        let library = MusicLibrarySnapshot(
            tracksByID: [
                "t1": LibraryTrack(
                    id: "t1",
                    title: "T",
                    artist: "A",
                    album: "B",
                    location: file,
                    isCloudOnly: false,
                    isDRMProtected: false,
                    fileExtension: "mp3"
                )
            ],
            playlists: [LibraryPlaylist(id: "p1", name: "Long Run", trackIDs: ["t1"])],
            albums: []
        )
        let plan = session.planAppleMusicPlaylist(playlistID: "p1", musicLibrary: library)
        XCTAssertEqual(plan.playlistName, "Long Run")
        XCTAssertTrue(plan.replaceQueue)
        XCTAssertTrue(plan.closeBrowser)
        XCTAssertEqual(plan.urls, [file])
    }

    func testAddFilesMergesUniquePaths() async throws {
        let suiteName = "MacLibrarySessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = MacLibrarySession(libraryQueueStore: LibraryQueueStore(defaults: defaults))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("one.mp3")
        let second = folder.appendingPathComponent("two.mp3")
        FileManager.default.createFile(atPath: first.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: second.path, contents: Data([0x02]))

        var scanning = false
        let r1 = await session.addFiles([first], into: [], setScanning: { scanning = $0 })
        XCTAssertFalse(scanning)
        XCTAssertEqual(r1.addedCount, 1)

        let r2 = await session.addFiles([first, second], into: r1.tracks, setScanning: { _ in })
        // first already present; second new
        XCTAssertEqual(r2.tracks.count, 2)
        XCTAssertEqual(r2.addedCount, 2) // scanned both, merge dedupes
    }

    private func makeTrack(
        fileName: String,
        title: String?,
        artist: String?,
        canCopy: Bool = true
    ) -> AudioTrack {
        AudioTrack(
            url: URL(fileURLWithPath: "/tmp/\(fileName)"),
            fileName: fileName,
            fileExtension: (fileName as NSString).pathExtension,
            title: title,
            artist: artist,
            album: nil,
            durationSeconds: nil,
            byteCount: 10,
            codecHint: nil,
            compatibility: canCopy ? .ready : TrackCompatibility(status: .blocked, messages: ["blocked"]),
            isSelected: false
        )
    }
}
