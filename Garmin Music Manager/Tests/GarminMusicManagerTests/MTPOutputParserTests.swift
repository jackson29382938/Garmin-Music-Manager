import XCTest
@testable import GarminMusicCore

final class MTPOutputParserTests: XCTestCase {
    func testMultiTrackPlaylistPreservesAllReferences() throws {
        let tracks = """
        Track ID: 100
        Title: First Song
        Artist: Test Artist
        Album: Road Mix
        Origfilename: 01 First Song.mp3
        File size: 1111
        Filetype: ISO MPEG-1 Audio Layer 3

        Track ID: 101
        Title: Second Song
        Artist: Test Artist
        Album: Road Mix
        Origfilename: 02 Second Song.mp3
        File size: 2222
        Filetype: ISO MPEG-1 Audio Layer 3

        Track ID: 102
        Title: Third Song
        Artist: Test Artist
        Album: Road Mix
        Origfilename: 03 Third Song.mp3
        File size: 3333
        Filetype: ISO MPEG-1 Audio Layer 3
        """

        let playlists = """
        Playlist ID: 900
        Name: Long Run
        100: 01 First Song.mp3
        101: 02 Second Song.mp3
        102: 03 Third Song.mp3
        """

        let snapshot = try MTPOutputParser.makeMusicSnapshot(
            tracksOutput: tracks,
            filesOutput: nil,
            playlistsOutput: playlists
        )

        let playlist = try XCTUnwrap(snapshot.collections.first { $0.kind == .playlist })
        XCTAssertEqual(playlist.name, "Long Run")
        XCTAssertEqual(playlist.fileIDs.count, 3)
        XCTAssertTrue(playlist.unmatchedItems.isEmpty)
    }

    func testUnmatchedPlaylistTracksArePreserved() throws {
        let tracks = """
        Track ID: 100
        Title: First Song
        Origfilename: 01 First Song.mp3
        File size: 1111
        Filetype: ISO MPEG-1 Audio Layer 3
        """

        let playlists = """
        Playlist ID: 900
        Name: Long Run
        100: 01 First Song.mp3
        999: Missing Song.mp3
        """

        let snapshot = try MTPOutputParser.makeMusicSnapshot(
            tracksOutput: tracks,
            filesOutput: nil,
            playlistsOutput: playlists
        )

        let playlist = try XCTUnwrap(snapshot.collections.first { $0.kind == .playlist })
        XCTAssertEqual(playlist.fileIDs.count, 1)
        XCTAssertEqual(playlist.unmatchedItems, ["Missing Song.mp3"])
        XCTAssertEqual(playlist.totalItemCount, 2)
    }

    func testStorageTreeBuildsParentPaths() throws {
        let files = """
        File ID: 1
        Filename: Music
        File size 0
        Filetype: Association/Directory

        File ID: 2
        Filename: Road Mix
        File size 0
        Parent ID: 1
        Filetype: Association/Directory

        File ID: 3
        Filename: Song.mp3
        File size 4096
        Parent ID: 2
        Filetype: ISO MPEG-1 Audio Layer 3
        """

        let snapshot = try MTPOutputParser.makeStorageSnapshot(filesOutput: files)
        let song = try XCTUnwrap(snapshot.files.first { $0.name == "Song.mp3" })
        XCTAssertEqual(song.path, "Music/Road Mix/Song.mp3")
        XCTAssertEqual(song.type, .audio)
    }

    func testGenericObjectsInsideMusicFolderAreShownAsAudio() throws {
        let files = """
        File ID: 1
        Filename: Music
        File size 0
        Filetype: Association/Directory

        File ID: 2
        Filename: Road Mix
        File size 0
        Parent ID: 1
        Filetype: Association/Directory

        File ID: 3
        Filename: GarminTrack001
        File size 4096
        Parent ID: 2
        Filetype: Unknown file type
        """

        let snapshot = try MTPOutputParser.makeMusicSnapshot(
            tracksOutput: nil,
            filesOutput: files,
            playlistsOutput: nil
        )

        let song = try XCTUnwrap(snapshot.files.first { $0.name == "GarminTrack001" })
        XCTAssertEqual(song.path, "Music/Road Mix/GarminTrack001")
        XCTAssertEqual(song.type, .audio)
    }

    func testNonAudioSidecarsInsideMusicFolderStayOutOfMusicSnapshot() throws {
        let files = """
        File ID: 1
        Filename: Music
        File size 0
        Filetype: Association/Directory

        File ID: 2
        Filename: cover.jpg
        File size 4096
        Parent ID: 1
        Filetype: Unknown file type

        File ID: 3
        Filename: library.db
        File size 4096
        Parent ID: 1
        Filetype: Unknown file type
        """

        let snapshot = try MTPOutputParser.makeMusicSnapshot(
            tracksOutput: nil,
            filesOutput: files,
            playlistsOutput: nil
        )

        XCTAssertTrue(snapshot.files.isEmpty)
    }

    func testNoDeviceOutputThrowsHelpfulError() {
        XCTAssertThrowsError(try MTPOutputParser.validateMTPOutput("No raw devices found.", allowNoPlaylists: false)) { error in
            let helperError = error as? MTPHelperError
            XCTAssertEqual(helperError?.code, "no-device")
        }
    }

    func testNoPlaylistsDoesNotMaskNoDevice() {
        XCTAssertThrowsError(try MTPOutputParser.validateMTPOutput("No playlists.\nNo devices found.", allowNoPlaylists: true)) { error in
            let helperError = error as? MTPHelperError
            XCTAssertEqual(helperError?.code, "no-device")
        }
    }

    func testParseTracksExtractsMetadata() {
        let tracks = """
        Track ID: 42
        Title: Test Song
        Artist: Artist Name
        Album: Album Name
        Origfilename: Test Song.mp3
        File size: 4096
        Filetype: ISO MPEG-1 Audio Layer 3
        """
        let parsed = MTPOutputParser.parseTracks(tracks)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.title, "Test Song")
        XCTAssertEqual(parsed.first?.trackID, "42")
    }

    func testParseDeviceName() {
        let output = "Friendly name: Fenix 7\n"
        XCTAssertEqual(MTPOutputParser.parseDeviceName(output), "Fenix 7")
    }
}
