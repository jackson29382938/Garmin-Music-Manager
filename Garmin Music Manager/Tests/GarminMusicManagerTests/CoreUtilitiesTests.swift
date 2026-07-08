import XCTest
@testable import GarminMusicCore

final class PathSanitizerTests: XCTestCase {
    func testSanitizeFileNameRemovesInvalidCharacters() {
        XCTAssertEqual(PathSanitizer.sanitizeFileName("Run/Workout?"), "Run-Workout-")
    }

    func testSanitizeFileNameUsesFallbackForEmptyInput() {
        XCTAssertEqual(PathSanitizer.sanitizeFileName("   "), "Garmin Playlist")
    }

    func testUniqueURLAppendsSuffixWhenFileExists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = folder.appendingPathComponent("Song.mp3")
        FileManager.default.createFile(atPath: first.path, contents: Data([0x01]))

        let unique = PathSanitizer.uniqueURL(in: folder, preferredFileName: "Song.mp3")
        XCTAssertNotEqual(unique.lastPathComponent, "Song.mp3")
        XCTAssertTrue(unique.lastPathComponent.hasPrefix("Song"))
    }
}

final class M3UWriterTests: XCTestCase {
    func testWritePlaylistUsesExtInfLines() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let trackURL = folder.appendingPathComponent("Artist - Song.mp3")
        FileManager.default.createFile(atPath: trackURL.path, contents: Data())

        let writer = M3UWriter()
        let playlistURL = try writer.writePlaylist(
            named: "Run Mix",
            tracks: [(trackURL, "Artist - Song", 201)],
            relativeTo: folder
        )

        let text = try String(contentsOf: playlistURL, encoding: .utf8)
        XCTAssertTrue(text.contains("#EXTM3U"))
        XCTAssertTrue(text.contains("#EXTINF:201,Artist - Song"))
        XCTAssertTrue(text.contains("Artist - Song.mp3"))
    }
}

final class MusicCompatibilityEvaluatorTests: XCTestCase {
    func testBlocksFLAC() {
        let url = URL(fileURLWithPath: "/tmp/track.flac")
        let result = MusicCompatibilityEvaluator.evaluate(
            url: url,
            ext: "flac",
            codecHint: nil,
            title: "Title",
            artist: "Artist",
            byteCount: 1_000
        )
        XCTAssertFalse(result.canCopy)
    }

    func testBlocksALACM4A() {
        let url = URL(fileURLWithPath: "/tmp/track.m4a")
        let result = MusicCompatibilityEvaluator.evaluate(
            url: url,
            ext: "m4a",
            codecHint: "alac",
            title: "Title",
            artist: "Artist",
            byteCount: 1_000
        )
        XCTAssertFalse(result.canCopy)
    }

    func testReadyMP3WithWarningsForMissingTags() {
        let url = URL(fileURLWithPath: "/tmp/track.mp3")
        let result = MusicCompatibilityEvaluator.evaluate(
            url: url,
            ext: "mp3",
            codecHint: nil,
            title: nil,
            artist: nil,
            byteCount: 1_000
        )
        XCTAssertTrue(result.canCopy)
        XCTAssertEqual(result.status, .warning)
    }

    func testNeedsConversionForFLACAndALAC() {
        XCTAssertTrue(MusicCompatibilityEvaluator.needsConversion(ext: "flac", codecHint: nil))
        XCTAssertTrue(MusicCompatibilityEvaluator.needsConversion(ext: "m4a", codecHint: "alac"))
        XCTAssertFalse(MusicCompatibilityEvaluator.needsConversion(ext: "mp3", codecHint: nil))
    }
}

final class MTPRetryPolicyTests: XCTestCase {
    func testDetectsTransientUSBErrors() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not open the usb connection"])
        XCTAssertTrue(MTPRetryPolicy.isTransientError(error))
    }

    func testDetectsHelperTimeoutAndDisconnectAsTransient() {
        XCTAssertTrue(MTPRetryPolicy.isTransientFailureMessage("The Garmin helper timed out."))
        XCTAssertTrue(MTPRetryPolicy.isTransientFailureMessage("USB transfer failed because the device disconnected."))
    }

    func testRunWithRetrySucceedsAfterTransientFailure() throws {
        var attempts = 0
        let value = try MTPRetryPolicy.runWithRetry {
            attempts += 1
            if attempts < 2 {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to open session"])
            }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(attempts, 2)
    }
}

final class SyncServiceTests: XCTestCase {
    func testFlatOrganizationUsesPlaylistRoot() {
        let path = SyncPathResolver.targetRelativePath(
            playlistName: "Run Mix",
            fileName: "Song.mp3",
            organization: .flat,
            artist: "Artist",
            albumComponents: []
        )
        XCTAssertEqual(path, "Run Mix/Song.mp3")
    }

    func testArtistOrganizationAddsArtistFolder() {
        let path = SyncPathResolver.targetRelativePath(
            playlistName: "Run Mix",
            fileName: "Song.mp3",
            organization: .byArtist,
            artist: "Test Artist",
            albumComponents: []
        )
        XCTAssertEqual(path, "Run Mix/Test Artist/Song.mp3")
    }
}
