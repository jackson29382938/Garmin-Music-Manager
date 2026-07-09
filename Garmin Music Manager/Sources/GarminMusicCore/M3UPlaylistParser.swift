import Foundation

/// Parses M3U/M3U8 playlist text and matches entries to on-device audio files.
/// Used for Garmin watches that store playlists as `.m3u8` rather than native MTP playlists.
public enum M3UPlaylistParser {
    public struct MatchResult: Equatable, Sendable {
        public var fileIDs: [String]
        public var unmatchedItems: [String]

        public init(fileIDs: [String], unmatchedItems: [String]) {
            self.fileIDs = fileIDs
            self.unmatchedItems = unmatchedItems
        }
    }

    /// Extract track path lines from M3U/M3U8/PLS-like text (skips comments and remote URLs).
    public static func parseTrackPaths(from text: String) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") { continue }

            // PLS format: File1=path
            let pathLine: String
            if let equals = line.range(of: "="),
               line[..<equals.lowerBound].lowercased().hasPrefix("file") {
                pathLine = String(line[equals.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                pathLine = line
            }
            guard !pathLine.isEmpty else { continue }

            let lower = pathLine.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("rtsp://") {
                continue
            }

            let key = normalizePath(pathLine)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            paths.append(pathLine)
        }
        return paths
    }

    /// Normalize Garmin/MTP paths for comparison.
    /// Examples:
    /// - `0:/MUSIC/FOO/BAR.MP3` → `music/foo/bar.mp3`
    /// - `\Music\Song.mp3` → `music/song.mp3`
    public static func normalizePath(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip storage prefix: `0:/MUSIC/...` or `0:MUSIC/...`
        if let colon = value.firstIndex(of: ":") {
            let after = value[value.index(after: colon)...]
            if after.hasPrefix("/") {
                value = String(after.dropFirst())
            } else {
                value = String(after)
            }
        }

        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Collapse repeated slashes
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        return value.lowercased()
    }

    public static func basename(of rawPath: String) -> String {
        let normalized = normalizePath(rawPath)
        guard let slash = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slash)...])
    }

    /// Match playlist path references to device files, preserving playlist order.
    /// Matching priority: full normalized path → path suffix → unique basename.
    public static func match(
        references: [String],
        files: [DeviceFile]
    ) -> MatchResult {
        let byFullPath = Dictionary(grouping: files) { normalizePath($0.path.isEmpty ? $0.name : $0.path) }
        let byName = Dictionary(grouping: files) { $0.name.lowercased() }
        let byBase = Dictionary(grouping: files) { basename(of: $0.path.isEmpty ? $0.name : $0.path) }

        var fileIDs: [String] = []
        var unmatched: [String] = []
        var usedIDs = Set<String>()

        for reference in references {
            let full = normalizePath(reference)
            let base = basename(of: reference)
            let display = reference.split(separator: "/").last.map(String.init) ?? reference

            if let match = firstUnused(byFullPath[full], used: usedIDs)
                ?? firstUnused(pathSuffixMatch(full, in: byFullPath), used: usedIDs)
                ?? uniqueUnused(byBase[base], used: usedIDs)
                ?? uniqueUnused(byName[base], used: usedIDs)
                ?? uniqueUnused(byName[display.lowercased()], used: usedIDs) {
                fileIDs.append(match.id)
                usedIDs.insert(match.id)
            } else {
                unmatched.append(display.isEmpty ? reference : display)
            }
        }

        return MatchResult(fileIDs: fileIDs, unmatchedItems: unmatched)
    }

    public static func playlistDisplayName(fromFileName fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let stem = url.deletingPathExtension().lastPathComponent
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fileName : trimmed
    }

    // MARK: - Private

    private static func firstUnused(_ files: [DeviceFile]?, used: Set<String>) -> DeviceFile? {
        files?.first { !used.contains($0.id) }
    }

    private static func uniqueUnused(_ files: [DeviceFile]?, used: Set<String>) -> DeviceFile? {
        guard let candidates = files?.filter({ !used.contains($0.id) }), candidates.count == 1 else {
            return nil
        }
        return candidates[0]
    }

    /// When full path fails, try matching if any device path ends with the playlist path
    /// (or vice versa) — covers missing/extra `Music/` prefixes.
    private static func pathSuffixMatch(
        _ full: String,
        in byFullPath: [String: [DeviceFile]]
    ) -> [DeviceFile]? {
        guard !full.isEmpty else { return nil }
        var hits: [DeviceFile] = []
        for (path, files) in byFullPath {
            if path == full || path.hasSuffix("/" + full) || full.hasSuffix("/" + path) {
                hits.append(contentsOf: files)
            }
        }
        return hits.isEmpty ? nil : hits
    }
}
