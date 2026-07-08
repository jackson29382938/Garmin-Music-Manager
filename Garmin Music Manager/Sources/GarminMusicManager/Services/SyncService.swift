import Foundation

final class SyncService {
    private let fileManager = FileManager.default
    private let playlistWriter = M3UWriter()

    func buildPreview(
        tracks: [AudioTrack],
        playlistName: String,
        destination: URL,
        settings: SyncSettings
    ) throws -> SyncPreview {
        let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
        let targetFolder = destination.appendingPathComponent(cleanPlaylistName, isDirectory: true)

        var items: [SyncPreviewItem] = []
        var totalBytes: Int64 = 0

        for track in tracks {
            let targetURL = resolveTargetURL(for: track, in: targetFolder, settings: settings)
            let action = resolveAction(for: track, targetURL: targetURL, settings: settings)
            if action == .copy || action == .replace || action == .keepBoth {
                totalBytes += track.byteCount
            }
            items.append(SyncPreviewItem(track: track, action: action, targetPath: targetURL.path))
        }

        return SyncPreview(items: items, totalBytesToCopy: totalBytes)
    }

    func sync(
        tracks: [AudioTrack],
        playlistName: String,
        destination: URL,
        settings: SyncSettings,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> SyncResult {
        try await Task.detached(priority: .userInitiated) {
            let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
            let targetFolder = destination.appendingPathComponent(cleanPlaylistName, isDirectory: true)
            try self.fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)

            var copiedURLs: [(url: URL, displayName: String, durationSeconds: Double?)] = []
            var skipped = 0
            var replaced = 0

            for (index, track) in tracks.enumerated() {
                try Task.checkCancellation()

                let targetURL = self.resolveTargetURL(for: track, in: targetFolder, settings: settings)
                let action = self.resolveAction(for: track, targetURL: targetURL, settings: settings)

                switch action {
                case .skipIdentical:
                    skipped += 1
                    progress(
                        Double(index + 1) / Double(max(tracks.count, 1)),
                        "Skipped identical: \(track.fileName)"
                    )
                case .replace:
                    try self.fileManager.createDirectory(
                        at: targetURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if self.fileManager.fileExists(atPath: targetURL.path) {
                        try self.fileManager.removeItem(at: targetURL)
                        replaced += 1
                    }
                    try self.fileManager.copyItem(at: track.url, to: targetURL)
                    copiedURLs.append((targetURL, track.playlistDisplayName, track.durationSeconds))
                    progress(
                        Double(index + 1) / Double(max(tracks.count, 1)),
                        "Replaced \(track.fileName)"
                    )
                case .keepBoth:
                    try self.fileManager.createDirectory(
                        at: targetURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let uniqueURL = FileNameSanitizer.uniqueURL(in: targetURL.deletingLastPathComponent(), preferredFileName: targetURL.lastPathComponent)
                    try self.fileManager.copyItem(at: track.url, to: uniqueURL)
                    copiedURLs.append((uniqueURL, track.playlistDisplayName, track.durationSeconds))
                    progress(
                        Double(index + 1) / Double(max(tracks.count, 1)),
                        "Copied as \(uniqueURL.lastPathComponent)"
                    )
                case .copy:
                    try self.fileManager.createDirectory(
                        at: targetURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try self.fileManager.copyItem(at: track.url, to: targetURL)
                    copiedURLs.append((targetURL, track.playlistDisplayName, track.durationSeconds))
                    progress(
                        Double(index + 1) / Double(max(tracks.count, 1)),
                        "Copied \(track.fileName)"
                    )
                }
            }

            var playlistURL = targetFolder.appendingPathComponent("\(cleanPlaylistName).m3u8")
            if settings.writePlaylist {
                playlistURL = try self.playlistWriter.writePlaylist(
                    named: cleanPlaylistName,
                    tracks: copiedURLs,
                    relativeTo: targetFolder
                )
            }

            return SyncResult(
                copiedCount: copiedURLs.count,
                skippedCount: skipped,
                replacedCount: replaced,
                playlistURL: playlistURL,
                targetFolder: targetFolder
            )
        }.value
    }

    private func resolveTargetURL(for track: AudioTrack, in targetFolder: URL, settings: SyncSettings) -> URL {
        var folder = targetFolder
        switch settings.organizationPolicy {
        case .flat:
            break
        case .byArtist:
            if let artist = track.artist?.nilIfEmpty {
                folder = folder.appendingPathComponent(FileNameSanitizer.sanitizePathComponent(artist), isDirectory: true)
            }
        case .byArtistAlbum:
            for component in track.organizationFolderComponents {
                folder = folder.appendingPathComponent(component, isDirectory: true)
            }
        }
        return folder.appendingPathComponent(FileNameSanitizer.safeFileName(for: track))
    }

    private func resolveAction(for track: AudioTrack, targetURL: URL, settings: SyncSettings) -> SyncPreviewItem.SyncAction {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return .copy
        }

        switch settings.overwritePolicy {
        case .skipIdentical:
            if isIdentical(source: track.url, target: targetURL, expectedSize: track.byteCount) {
                return .skipIdentical
            }
            return .replace
        case .replace:
            return .replace
        case .keepBoth:
            return .keepBoth
        }
    }

    private func isIdentical(source: URL, target: URL, expectedSize: Int64) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: target.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size == expectedSize
    }
}
