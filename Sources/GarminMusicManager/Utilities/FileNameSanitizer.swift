import Foundation

enum FileNameSanitizer {
    private static let invalidFileNameCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")

    static func sanitizeFileName(_ name: String, fallback: String = "Garmin Playlist") -> String {
        let result = name
            .components(separatedBy: invalidFileNameCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.nilIfEmpty ?? fallback
    }

    static func sanitizePathComponent(_ name: String) -> String {
        sanitizeFileName(name, fallback: "Unknown")
    }

    static func safeFileName(for track: AudioTrack) -> String {
        let base = track.playlistDisplayName.nilIfEmpty
            ?? track.fileName.replacingOccurrences(of: ".\(track.fileExtension)", with: "")
        let cleaned = sanitizeFileName(base, fallback: "Track")
        return "\(cleaned).\(track.fileExtension)"
    }

    static func uniqueURL(in folderURL: URL, preferredFileName: String) -> URL {
        let preferredURL = folderURL.appendingPathComponent(preferredFileName)
        if !FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName = "\(stem) \(index).\(ext)"
            let candidateURL = folderURL.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return folderURL.appendingPathComponent(UUID().uuidString + "." + ext)
    }
}
