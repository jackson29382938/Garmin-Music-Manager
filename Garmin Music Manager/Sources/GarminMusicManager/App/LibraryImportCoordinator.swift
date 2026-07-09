import Foundation
import GarminMusicCore

/// Mac-side library import helpers extracted from `AppModel`.
@MainActor
final class LibraryImportCoordinator {
    private let scanner = MusicScanner()

    struct ImportExpansion {
        var audioURLs: [URL]
        var playlistsExpanded: Int
    }

    func scanFiles(
        _ urls: [URL],
        fastImport: Bool = false,
        maxConcurrency: Int = 0
    ) async -> [AudioTrack] {
        await scanner.scanFiles(urls, fastImport: fastImport, maxConcurrency: maxConcurrency)
    }

    func findAudioFiles(in folder: URL) -> [URL] {
        scanner.findAudioFiles(in: folder)
    }

    /// Expands folders and playlist files into concrete local audio URLs.
    func expandImportURLs(_ urls: [URL]) -> ImportExpansion {
        let result = scanner.expandImportURLs(urls)
        return ImportExpansion(audioURLs: result.audioURLs, playlistsExpanded: result.playlistsExpanded)
    }

    func expandDroppedURLs(_ urls: [URL]) -> ImportExpansion {
        expandImportURLs(urls)
    }

    func mergeTracks(existing: [AudioTrack], newTracks: [AudioTrack]) -> [AudioTrack] {
        var tracks = existing
        var seen = Set(tracks.map(\.url))
        for track in newTracks where !seen.contains(track.url) {
            tracks.append(track)
            seen.insert(track.url)
        }
        tracks.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return tracks
    }
}
