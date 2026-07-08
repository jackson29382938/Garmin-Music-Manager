import Foundation

/// Pure helpers for MTP playlist create-vs-update decisions (no USB required).
public enum MTPPlaylistNameMatch {
    /// First playlist whose name matches `desired` case-insensitively.
    public static func existingID(named desired: String, names: [(id: UInt32, name: String)]) -> UInt32? {
        names.first {
            $0.name.localizedCaseInsensitiveCompare(desired) == .orderedSame
        }?.id
    }
}

public enum PathSanitizer {
    private static let invalidFileNameCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")

    public static func sanitizeFileName(_ name: String, fallback: String = "Garmin Playlist") -> String {
        let result = name
            .components(separatedBy: invalidFileNameCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    public static func sanitizePathComponent(_ name: String) -> String {
        sanitizeFileName(name, fallback: "Unknown")
    }

    public static func uniqueURL(in folderURL: URL, preferredFileName: String, fileManager: FileManager = .default) -> URL {
        let preferredURL = folderURL.appendingPathComponent(preferredFileName)
        if !fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidateURL = folderURL.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return folderURL.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }
}

public struct M3UWriter {
    public init() {}

    public struct Entry: Hashable, Sendable {
        public var relativePath: String
        public var displayName: String
        public var durationSeconds: Double?

        public init(relativePath: String, displayName: String, durationSeconds: Double? = nil) {
            self.relativePath = relativePath
            self.displayName = displayName
            self.durationSeconds = durationSeconds
        }
    }

    /// Builds `#EXTM3U` text. `relativePath` should be relative to the playlist file's folder
    /// and use `/` separators (e.g. `Artist/Album/Song.mp3`).
    public func playlistText(entries: [Entry]) -> String {
        var lines: [String] = ["#EXTM3U"]
        for entry in entries {
            let duration = entry.durationSeconds.map { String(Int($0.rounded())) } ?? "-1"
            let path = entry.relativePath
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { continue }
            lines.append("#EXTINF:\(duration),\(entry.displayName)")
            lines.append(path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func writePlaylist(
        named playlistName: String,
        entries: [Entry],
        to folder: URL
    ) throws -> URL {
        let cleanName = PathSanitizer.sanitizeFileName(playlistName)
        let playlistURL = folder.appendingPathComponent("\(cleanName).m3u8")
        try playlistText(entries: entries).write(to: playlistURL, atomically: true, encoding: .utf8)
        return playlistURL
    }

    public func writePlaylist(
        named playlistName: String,
        tracks: [(url: URL, displayName: String, durationSeconds: Double?)],
        relativeTo folder: URL
    ) throws -> URL {
        let folderPath = folder.standardizedFileURL.path
        let entries = tracks.map { track -> Entry in
            let trackPath = track.url.standardizedFileURL.path
            let relative: String
            if trackPath.hasPrefix(folderPath + "/") {
                relative = String(trackPath.dropFirst(folderPath.count + 1))
            } else {
                relative = track.url.lastPathComponent
            }
            return Entry(
                relativePath: relative,
                displayName: track.displayName,
                durationSeconds: track.durationSeconds
            )
        }
        return try writePlaylist(named: playlistName, entries: entries, to: folder)
    }
}

/// Parses local `.m3u` / `.m3u8` files into file URLs (skips remote http(s) entries).
public enum M3UImporter {
    public static func localTrackURLs(from playlistURL: URL) throws -> [URL] {
        let text = try String(contentsOf: playlistURL, encoding: .utf8)
        let base = playlistURL.deletingLastPathComponent()
        var urls: [URL] = []
        var seen = Set<String>()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("rtsp://") {
                continue
            }

            let candidate: URL
            if line.hasPrefix("/") {
                candidate = URL(fileURLWithPath: line)
            } else if line.contains("://") {
                guard let remote = URL(string: line), remote.isFileURL else { continue }
                candidate = remote
            } else {
                candidate = base.appendingPathComponent(line)
            }

            let standardized = candidate.standardizedFileURL
            let key = standardized.path
            guard !seen.contains(key) else { continue }
            guard FileManager.default.fileExists(atPath: standardized.path) else { continue }
            seen.insert(key)
            urls.append(standardized)
        }
        return urls
    }
}

public struct TrackCompatibility: Hashable {
    public enum Status: String, Hashable {
        case ready = "Ready"
        case warning = "Warning"
        case blocked = "Blocked"
    }

    public let status: Status
    public let messages: [String]

    public var canCopy: Bool {
        status != .blocked
    }

    public static let ready = TrackCompatibility(status: .ready, messages: ["Compatible"])

    public init(status: Status, messages: [String]) {
        self.status = status
        self.messages = messages
    }
}

public enum MusicCompatibilityEvaluator {
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "adts", "wav"
    ]

    public static let supportedPlaylistExtensions: Set<String> = [
        "m3u", "m3u8", "wpl", "zpl"
    ]

    public static let knownUnsupportedExtensions: Set<String> = [
        "aif", "aiff", "alac", "flac", "m4p", "ogg", "opus", "wma"
    ]

    public static func evaluate(
        url: URL,
        ext: String,
        codecHint: String?,
        title: String?,
        artist: String?,
        byteCount: Int64
    ) -> TrackCompatibility {
        var messages: [String] = []
        var blocked = false

        if supportedPlaylistExtensions.contains(ext) {
            return TrackCompatibility(
                status: .warning,
                messages: ["Playlist file; copied as-is, but referenced files must also be present"]
            )
        }

        if knownUnsupportedExtensions.contains(ext) {
            blocked = true
            messages.append(".\(ext) is not supported by Garmin watches")
        } else if !supportedAudioExtensions.contains(ext) {
            blocked = true
            messages.append("Unsupported extension .\(ext)")
        }

        if ext == "m4a" || ext == "m4b", codecHint?.lowercased() == "alac" {
            blocked = true
            messages.append("M4A uses Apple Lossless/ALAC, which Garmin does not support")
        }

        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.contains("protected") || lowerName.contains("drm") || ext == "m4p" {
            blocked = true
            messages.append("Possible DRM-protected file")
        }

        if title?.isEmpty ?? true {
            messages.append("Missing title tag")
        }
        if artist?.isEmpty ?? true {
            messages.append("Missing artist tag")
        }

        if byteCount > 250_000_000 {
            messages.append("Large file; consider compressing before copying")
        }

        if blocked {
            return TrackCompatibility(status: .blocked, messages: messages)
        }
        if messages.isEmpty {
            return .ready
        }
        return TrackCompatibility(status: .warning, messages: messages)
    }

    public static func needsConversion(ext: String, codecHint: String?) -> Bool {
        if ext == "flac" || ext == "alac" { return true }
        if (ext == "m4a" || ext == "m4b"), codecHint?.lowercased() == "alac" { return true }
        return false
    }
}

public enum SyncPathResolver {
    public enum Organization: String {
        case flat
        case byArtist
        case byArtistAlbum
    }

    public static func targetRelativePath(
        playlistName: String,
        fileName: String,
        organization: Organization,
        artist: String?,
        albumComponents: [String]
    ) -> String {
        var components = [PathSanitizer.sanitizeFileName(playlistName)]
        switch organization {
        case .flat:
            break
        case .byArtist:
            if let artist, !artist.isEmpty {
                components.append(PathSanitizer.sanitizePathComponent(artist))
            }
        case .byArtistAlbum:
            components.append(contentsOf: albumComponents)
        }
        components.append(PathSanitizer.sanitizeFileName(fileName, fallback: "Track"))
        return components.joined(separator: "/")
    }
}
