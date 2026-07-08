import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

@MainActor
final class TrackPreparationTests: XCTestCase {
    func testPrepareTracksWithoutConversionLeavesTracksUnchanged() {
        let track = makeFLACTrack()
        let coordinator = SyncCoordinator()
        var settings = SyncSettings.default
        settings.convertIncompatibleFormats = false

        let result = coordinator.prepareTracks([track], settings: settings)

        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks[0].fileExtension, "flac")
        XCTAssertEqual(result.convertedCount, 0)
        XCTAssertTrue(result.conversionFailures.isEmpty)
    }

    func testPrepareTracksReportsMissingFFmpegWhenConversionRequested() {
        let track = makeFLACTrack()
        let coordinator = SyncCoordinator()
        var settings = SyncSettings.default
        settings.convertIncompatibleFormats = true

        // If ffmpeg is installed on the machine, conversion may succeed instead.
        // Assert the API always returns a structured result either way.
        let result = coordinator.prepareTracks([track], settings: settings)

        XCTAssertEqual(result.tracks.count, 1)
        if result.convertedCount > 0 {
            XCTAssertEqual(result.tracks[0].fileExtension, "m4a")
            XCTAssertTrue(result.conversionFailures.isEmpty)
        } else {
            // No ffmpeg (or convert failed): original kept and failure reported when needed.
            if MusicCompatibilityEvaluator.needsConversion(ext: track.fileExtension, codecHint: track.codecHint) {
                // When convert is on and track needs conversion but wasn't converted,
                // either ffmpeg missing message or a conversion failure is expected.
                // If ffmpeg is available but conversion still failed, failures is non-empty.
                // If ffmpeg missing, failures is non-empty.
                // The only invalid state is silent no-op with empty failures and unconverted FLAC
                // while convert is enabled — that was the old bug.
                let stillNeeds = MusicCompatibilityEvaluator.needsConversion(
                    ext: result.tracks[0].fileExtension,
                    codecHint: result.tracks[0].codecHint
                )
                if stillNeeds {
                    XCTAssertFalse(
                        result.conversionFailures.isEmpty,
                        "Conversion issues must be reported, not silent"
                    )
                }
            }
        }
    }

    func testPreparedTracksWrapperMatchesPrepareTracks() {
        let track = makeMP3Track()
        let coordinator = SyncCoordinator()
        let settings = SyncSettings.default
        let wrapped = coordinator.preparedTracks([track], settings: settings)
        let full = coordinator.prepareTracks([track], settings: settings).tracks
        XCTAssertEqual(wrapped.map(\.id), full.map(\.id))
    }

    private func makeFLACTrack() -> AudioTrack {
        AudioTrack(
            url: URL(fileURLWithPath: "/tmp/song.flac"),
            fileName: "song.flac",
            fileExtension: "flac",
            title: "Song",
            artist: "Artist",
            album: nil,
            durationSeconds: 120,
            byteCount: 5_000_000,
            codecHint: "flac",
            compatibility: MusicCompatibilityEvaluator.evaluate(
                url: URL(fileURLWithPath: "/tmp/song.flac"),
                ext: "flac",
                codecHint: "flac",
                title: "Song",
                artist: "Artist",
                byteCount: 5_000_000
            ),
            isSelected: true
        )
    }

    private func makeMP3Track() -> AudioTrack {
        AudioTrack(
            url: URL(fileURLWithPath: "/tmp/song.mp3"),
            fileName: "song.mp3",
            fileExtension: "mp3",
            title: "Song",
            artist: "Artist",
            album: nil,
            durationSeconds: 120,
            byteCount: 3_000_000,
            codecHint: "mp3",
            compatibility: .ready,
            isSelected: true
        )
    }
}
