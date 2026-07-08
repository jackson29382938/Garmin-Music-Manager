import Foundation
import GarminMusicCore

enum FileNameSanitizer {
    static func sanitizeFileName(_ name: String, fallback: String = "Garmin Playlist") -> String {
        PathSanitizer.sanitizeFileName(name, fallback: fallback)
    }

    static func sanitizePathComponent(_ name: String) -> String {
        PathSanitizer.sanitizePathComponent(name)
    }

    static func safeFileName(for track: AudioTrack) -> String {
        let base = track.playlistDisplayName.nilIfEmpty
            ?? track.fileName.replacingOccurrences(of: ".\(track.fileExtension)", with: "")
        let cleaned = sanitizeFileName(base, fallback: "Track")
        return "\(cleaned).\(track.fileExtension)"
    }

    static func uniqueURL(in folderURL: URL, preferredFileName: String) -> URL {
        PathSanitizer.uniqueURL(in: folderURL, preferredFileName: preferredFileName)
    }
}
