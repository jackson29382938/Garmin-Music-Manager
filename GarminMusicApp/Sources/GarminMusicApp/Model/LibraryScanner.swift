import Foundation
import GarminMusicCore

/// Cross-platform folder scanner. Enumerates audio files by extension and asks
/// the shared `MusicCompatibilityEvaluator` for each file's Garmin verdict.
/// No AVFoundation / platform media frameworks, so it behaves the same on
/// Windows, macOS, and Linux.
enum LibraryScanner {
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "adts", "wav",
        "flac", "alac", "aif", "aiff", "ogg", "opus", "wma", "m4p"
    ]

    static func scan(folder: URL) -> [LibraryTrack] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var tracks: [LibraryTrack] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            // No tag reading on this cross-platform path, so derive a title/artist
            // from the file name and parent folder. This keeps the verdict focused
            // on format/size compatibility instead of flagging every file for a
            // "missing title" it was never given a chance to have.
            let title = (url.lastPathComponent as NSString).deletingPathExtension
            let artist = url.deletingLastPathComponent().lastPathComponent
            let compatibility = MusicCompatibilityEvaluator.evaluate(
                url: url,
                ext: ext,
                codecHint: nil,
                title: title.isEmpty ? nil : title,
                artist: artist.isEmpty ? nil : artist,
                byteCount: size
            )
            tracks.append(LibraryTrack(url: url, byteCount: size, compatibility: compatibility))
        }

        return tracks.sorted {
            $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
        }
    }

    /// Lists the contents of a destination ("On Watch") folder, one level deep
    /// per subfolder, returning audio and playlist files first.
    static func listWatchFolder(_ folder: URL) -> [WatchFile] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let base = folder.standardizedFileURL.path
        var files: [WatchFile] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let full = url.standardizedFileURL.path
            let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            files.append(WatchFile(
                name: url.lastPathComponent,
                relativePath: relative,
                byteCount: size,
                isAudio: audioExtensions.contains(ext) || ext == "m3u8" || ext == "m3u"
            ))
        }
        return files.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }
}
