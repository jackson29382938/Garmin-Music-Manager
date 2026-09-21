import Foundation
import GarminMusicCore

struct SyncOptions {
    var organization: OrganizationChoice
    var overwrite: OverwriteChoice
    var writePlaylist: Bool
}

struct SyncOutcome {
    var copied: Int
    var skipped: Int
    var replaced: Int
    var playlistPath: String?
    var destinationFolder: String
}

/// Cross-platform "send to watch" that copies selected tracks into a destination
/// folder (a mounted Garmin volume or any folder) and writes an `.m3u8`
/// playlist. Reuses the shared engine's `PathSanitizer`, `SyncPathResolver`
/// heuristics, and `M3UWriter`. Blocking file IO is offloaded so the UI stays
/// responsive; all progress callbacks run on the caller's actor.
struct FolderSyncEngine {
    private let playlistWriter = M3UWriter()

    func send(
        tracks: [LibraryTrack],
        playlistName: String,
        destination: URL,
        options: SyncOptions,
        progress: (Double, String) -> Void
    ) async throws -> SyncOutcome {
        let cleanPlaylist = PathSanitizer.sanitizeFileName(playlistName)
        let playlistFolder = destination.appendingPathComponent(cleanPlaylist, isDirectory: true)
        try FileManager.default.createDirectory(at: playlistFolder, withIntermediateDirectories: true)

        var copied = 0
        var skipped = 0
        var replaced = 0
        var playlistEntries: [M3UWriter.Entry] = []
        let total = max(tracks.count, 1)

        for (index, track) in tracks.enumerated() {
            let relativeComponents = Self.relativeComponents(for: track, organization: options.organization)
            let relativePath = relativeComponents.joined(separator: "/")
            let targetURL = playlistFolder.appendingPathComponent(relativePath)

            progress(Double(index) / Double(total), "Copying \(track.fileName)…")

            let action = Self.resolveAction(
                source: track.url,
                target: targetURL,
                sourceSize: track.byteCount,
                overwrite: options.overwrite
            )

            switch action {
            case .skip:
                skipped += 1
                playlistEntries.append(Self.entry(relativePath: relativePath, track: track))
            case .copy(let finalURL):
                try await Self.copyOffMain(from: track.url, to: finalURL, replaceExisting: false)
                copied += 1
                playlistEntries.append(Self.entry(relativePath: Self.relative(of: finalURL, under: playlistFolder) ?? relativePath, track: track))
            case .replace(let finalURL):
                try await Self.copyOffMain(from: track.url, to: finalURL, replaceExisting: true)
                copied += 1
                replaced += 1
                playlistEntries.append(Self.entry(relativePath: relativePath, track: track))
            }
        }

        var playlistPath: String?
        if options.writePlaylist, !playlistEntries.isEmpty {
            let url = try playlistWriter.writePlaylist(
                named: cleanPlaylist,
                entries: playlistEntries,
                to: playlistFolder
            )
            playlistPath = url.path
        }

        progress(1, "Done.")
        return SyncOutcome(
            copied: copied,
            skipped: skipped,
            replaced: replaced,
            playlistPath: playlistPath,
            destinationFolder: playlistFolder.path
        )
    }

    // MARK: - Planning

    private enum Action {
        case skip
        case copy(URL)
        case replace(URL)
    }

    private static func resolveAction(
        source: URL,
        target: URL,
        sourceSize: Int64,
        overwrite: OverwriteChoice
    ) -> Action {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: target.path) else {
            return .copy(target)
        }
        switch overwrite {
        case .skipIdentical:
            let targetSize = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            if targetSize == sourceSize {
                return .skip
            }
            return .replace(target)
        case .replace:
            return .replace(target)
        case .keepBoth:
            let unique = PathSanitizer.uniqueURL(
                in: target.deletingLastPathComponent(),
                preferredFileName: target.lastPathComponent
            )
            return .copy(unique)
        }
    }

    private static func relativeComponents(for track: LibraryTrack, organization: OrganizationChoice) -> [String] {
        var components: [String] = []
        let parent = track.url.deletingLastPathComponent()
        switch organization {
        case .flat:
            break
        case .byArtist:
            let artist = parent.lastPathComponent
            if !artist.isEmpty { components.append(PathSanitizer.sanitizePathComponent(artist)) }
        case .byArtistAlbum:
            let album = parent.lastPathComponent
            let artist = parent.deletingLastPathComponent().lastPathComponent
            if !artist.isEmpty { components.append(PathSanitizer.sanitizePathComponent(artist)) }
            if !album.isEmpty { components.append(PathSanitizer.sanitizePathComponent(album)) }
        }
        components.append(PathSanitizer.sanitizeFileName(track.fileName, fallback: "Track"))
        return components
    }

    private static func entry(relativePath: String, track: LibraryTrack) -> M3UWriter.Entry {
        M3UWriter.Entry(
            relativePath: relativePath,
            displayName: (track.fileName as NSString).deletingPathExtension,
            durationSeconds: nil
        )
    }

    private static func relative(of url: URL, under folder: URL) -> String? {
        let base = folder.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

    private static func copyOffMain(from source: URL, to target: URL, replaceExisting: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if replaceExisting, fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source, to: target)
        }.value
    }
}
