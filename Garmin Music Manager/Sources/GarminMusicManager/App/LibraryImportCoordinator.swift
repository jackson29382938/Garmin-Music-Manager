import Foundation
import GarminMusicCore

/// Mac-side library import helpers extracted from `AppModel`.
@MainActor
final class LibraryImportCoordinator {
    private let scanner = MusicScanner()

    func scanFiles(_ urls: [URL]) async -> [AudioTrack] {
        await scanner.scanFiles(urls)
    }

    func findAudioFiles(in folder: URL) -> [URL] {
        scanner.findAudioFiles(in: folder)
    }

    func expandDroppedURLs(_ urls: [URL]) -> [URL] {
        var fileURLs: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                fileURLs.append(contentsOf: scanner.findAudioFiles(in: url))
            } else {
                fileURLs.append(url)
            }
        }
        return fileURLs
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
