import Foundation

struct M3UWriter {
    func writePlaylist(
        named playlistName: String,
        tracks: [(url: URL, displayName: String, durationSeconds: Double?)],
        relativeTo folder: URL
    ) throws -> URL {
        let cleanName = FileNameSanitizer.sanitizeFileName(playlistName)
        let playlistURL = folder.appendingPathComponent("\(cleanName).m3u8")

        var lines: [String] = ["#EXTM3U"]
        for track in tracks {
            let duration = track.durationSeconds.map { String(Int($0.rounded())) } ?? "-1"
            lines.append("#EXTINF:\(duration),\(track.displayName)")
            lines.append(track.url.lastPathComponent)
        }

        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: playlistURL, atomically: true, encoding: .utf8)
        return playlistURL
    }
}
