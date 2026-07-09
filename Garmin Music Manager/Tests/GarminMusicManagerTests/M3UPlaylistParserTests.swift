import XCTest
@testable import GarminMusicCore

final class M3UPlaylistParserTests: XCTestCase {
    func testParseGarminStylePathsSkipsCommentsAndDuplicates() {
        let text = """
        #EXTM3U
        #EXTINF:123,Song
        0:/MUSIC/FOO/01 SONG.MP3
        0:/MUSIC/FOO/01 SONG.MP3
        https://example.com/x.mp3
        0:/MUSIC/BAR/02 OTHER.MP3
        """
        let paths = M3UPlaylistParser.parseTrackPaths(from: text)
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].localizedCaseInsensitiveContains("01 SONG"))
        XCTAssertTrue(paths[1].localizedCaseInsensitiveContains("02 OTHER"))
    }

    func testNormalizePathStripsStoragePrefixAndCase() {
        XCTAssertEqual(
            M3UPlaylistParser.normalizePath("0:/MUSIC/ARTIST/ALBUM/TRACK.MP3"),
            "music/artist/album/track.mp3"
        )
        XCTAssertEqual(
            M3UPlaylistParser.normalizePath("\\Music\\Track.mp3"),
            "music/track.mp3"
        )
        XCTAssertEqual(
            M3UPlaylistParser.basename(of: "0:/MUSIC/FOO/Bar.MP3"),
            "bar.mp3"
        )
    }

    func testMatchByBasenameWhenDevicePathsAreFlat() {
        let files = [
            makeFile(objectID: "1", name: "10 Ironic - 2015 Remaster.mp3", path: "10 Ironic - 2015 Remaster.mp3"),
            makeFile(objectID: "2", name: "01 Loser.mp3", path: "01 Loser.mp3"),
            makeFile(objectID: "3", name: "Other.mp3", path: "Other.mp3")
        ]
        let refs = [
            "0:/MUSIC/ALANIS MORISSETTE/JAGGED LITTLE PILL/10 IRONIC - 2015 REMASTER.MP3",
            "0:/MUSIC/BECK/MELLOW GOLD/01 LOSER.MP3",
            "0:/MUSIC/MISSING/NOPE.MP3"
        ]
        let result = M3UPlaylistParser.match(references: refs, files: files)
        XCTAssertEqual(result.fileIDs, ["mtp:1", "mtp:2"])
        XCTAssertEqual(result.unmatchedItems, ["NOPE.MP3"])
    }

    func testMatchPrefersFullPathWhenAvailable() {
        let files = [
            makeFile(objectID: "10", name: "Track.mp3", path: "Music/A/Track.mp3"),
            makeFile(objectID: "11", name: "Track.mp3", path: "Music/B/Track.mp3")
        ]
        let refs = ["0:/MUSIC/B/TRACK.MP3"]
        let result = M3UPlaylistParser.match(references: refs, files: files)
        XCTAssertEqual(result.fileIDs, ["mtp:11"])
        XCTAssertTrue(result.unmatchedItems.isEmpty)
    }

    func testPlaylistDisplayNameStripsExtension() {
        XCTAssertEqual(M3UPlaylistParser.playlistDisplayName(fromFileName: "garmin_run.m3u8"), "garmin_run")
        XCTAssertEqual(M3UPlaylistParser.playlistDisplayName(fromFileName: "Toby Keith.m3u8"), "Toby Keith")
    }

    private func makeFile(objectID: String, name: String, path: String) -> DeviceFile {
        DeviceFile(
            objectID: objectID,
            name: name,
            type: .audio,
            size: 1,
            path: path,
            backendKind: .mtp
        )
    }
}
