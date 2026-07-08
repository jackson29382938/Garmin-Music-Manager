import Foundation
import GarminMusicCore

@MainActor
final class SyncCoordinator {
    private let syncService = SyncService()
    private let audioConverter = AudioConverter()

    func buildMountedPreview(
        tracks: [AudioTrack],
        playlistName: String,
        destination: URL,
        settings: SyncSettings
    ) throws -> SyncPreview {
        try syncService.buildPreview(
            tracks: preparedTracks(tracks, settings: settings),
            playlistName: playlistName,
            destination: destination,
            settings: settings
        )
    }

    func buildMTPPreview(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        deviceFiles: [DeviceFile]
    ) -> SyncPreview {
        let prepared = preparedTracks(tracks, settings: settings)
        let plan = MTPSyncPlanner.buildPlan(
            tracks: prepared,
            playlistName: playlistName,
            settings: settings,
            deviceFiles: deviceFiles
        )
        return SyncPreview(items: plan.previewItems, totalBytesToCopy: plan.totalBytesToTransfer)
    }

    func executeMTPPlan(
        _ plan: MTPSyncPlan,
        deviceBrowser: DeviceBrowserStore,
        playlistName: String,
        settings: SyncSettings,
        refreshAfter: Bool = true,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async -> MTPSyncResult {
        let skipped = plan.skippedCount
        let uploads = plan.uploads

        if plan.transferCount == 0 && uploads.isEmpty {
            progress(0.85, settings.writePlaylist ? "Building playlist…" : nil)
            let playlist = await maybeCreateMTPPlaylist(
                plan: plan,
                failedDisplayNames: [],
                deviceBrowser: deviceBrowser,
                playlistName: playlistName,
                settings: settings,
                refreshFirst: true,
                progress: progress
            )
            progress(1, playlist.map { "Playlist “\($0)” ready." })
            return MTPSyncResult(
                uploadedCount: 0,
                skippedCount: skipped,
                replacedCount: 0,
                failedCount: 0,
                playlistName: playlist
            )
        }

        progress(0.05, "Preparing \(plan.transferCount) track(s) for Garmin…")

        guard !uploads.isEmpty else {
            progress(1, nil)
            return MTPSyncResult(uploadedCount: 0, skippedCount: skipped, replacedCount: 0, failedCount: 0)
        }

        // Chunk uploads for partial recovery. Progress comes from libmtp NDJSON
        // events (per-byte within each file) remapped across the full plan.
        let chunkSize = MTPHelperClient.uploadChunkSize
        let chunks: [[DeviceUploadFile]] = stride(from: 0, to: uploads.count, by: chunkSize).map {
            Array(uploads[$0..<min($0 + chunkSize, uploads.count)])
        }

        let totalBytes = max(plan.totalBytesToTransfer, 1)
        var completed = 0
        var failedItems: [String] = []
        var completedBytes: Int64 = 0

        let transferBase = 0.08
        let transferSpan = settings.writePlaylist ? 0.78 : 0.88

        for chunk in chunks {
            try? Task.checkCancellation()
            if Task.isCancelled {
                break
            }
            let chunkBytes = chunk.reduce(Int64(0)) { partial, file in
                let size = (try? URL(fileURLWithPath: file.localPath).resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init) ?? 0
                return partial + max(size, 0)
            }
            let bytesBeforeChunk = completedBytes

            progress(
                transferBase + transferSpan * (Double(bytesBeforeChunk) / Double(totalBytes)),
                "Uploading \(completed + 1)–\(min(completed + chunk.count, uploads.count)) of \(uploads.count)…"
            )

            if let uploadResult = await deviceBrowser.upload(chunk, refreshAfter: false, onProgress: { event in
                let withinChunk = event.overallFraction * Double(max(chunkBytes, 1))
                let overallBytes = Double(bytesBeforeChunk) + withinChunk
                let fraction = transferBase + transferSpan * min(1, overallBytes / Double(totalBytes))
                progress(fraction, event.displayMessage)
            }) {
                completed += uploadResult.completedCount
                failedItems.append(contentsOf: uploadResult.failedItems)
            } else {
                failedItems.append(contentsOf: chunk.map(\.displayName))
            }
            completedBytes += chunkBytes
        }

        let failedNames = Set(failedItems)
        let replacedCount = plan.items.filter {
            $0.action == .replace && !failedNames.contains($0.track.displayName)
        }.count

        progress(0.90, "Refreshing Garmin library…")
        await deviceBrowser.refresh(force: true)

        let playlist = await maybeCreateMTPPlaylist(
            plan: plan,
            failedDisplayNames: failedNames,
            deviceBrowser: deviceBrowser,
            playlistName: playlistName,
            settings: settings,
            refreshFirst: false,
            progress: progress
        )

        if refreshAfter, playlist != nil {
            // Pull playlist collection into the browser after create.
            await deviceBrowser.refresh(force: true)
        }

        progress(1, nil)

        return MTPSyncResult(
            uploadedCount: completed,
            skippedCount: skipped,
            replacedCount: replacedCount,
            failedCount: failedItems.count,
            playlistName: playlist
        )
    }

    private func maybeCreateMTPPlaylist(
        plan: MTPSyncPlan,
        failedDisplayNames: Set<String>,
        deviceBrowser: DeviceBrowserStore,
        playlistName: String,
        settings: SyncSettings,
        refreshFirst: Bool,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async -> String? {
        guard settings.writePlaylist else { return nil }
        guard deviceBrowser.backendKind == .mtp else { return nil }

        if refreshFirst {
            await deviceBrowser.refresh(force: true)
        }

        let tracks = MTPPlaylistResolver.playlistTracks(
            plan: plan,
            failedDisplayNames: failedDisplayNames,
            deviceFiles: deviceBrowser.files
        )
        guard !tracks.isEmpty else {
            progress(0.96, "Playlist skipped (no matching tracks on the Garmin yet).")
            return nil
        }

        let cleanName = FileNameSanitizer.sanitizeFileName(playlistName)
        progress(0.95, "Creating playlist “\(cleanName)”…")
        if let result = await deviceBrowser.createPlaylist(name: cleanName, tracks: tracks) {
            progress(0.98, result.message)
            return cleanName
        }
        if let error = deviceBrowser.lastError {
            progress(0.98, "Playlist not created: \(error)")
        }
        return nil
    }

    func syncMounted(
        tracks: [AudioTrack],
        playlistName: String,
        destination: URL,
        settings: SyncSettings,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> SyncResult {
        try await syncService.sync(
            tracks: preparedTracks(tracks, settings: settings),
            playlistName: playlistName,
            destination: destination,
            settings: settings,
            progress: progress
        )
    }

    func preparedTracks(_ tracks: [AudioTrack], settings: SyncSettings) -> [AudioTrack] {
        guard settings.convertIncompatibleFormats, audioConverter.isAvailable else {
            return tracks
        }

        return tracks.map { track in
            guard MusicCompatibilityEvaluator.needsConversion(ext: track.fileExtension, codecHint: track.codecHint) else {
                return track
            }
            guard let convertedURL = try? audioConverter.convertToAAC(source: track.url) else {
                return track
            }
            let byteCount = (try? FileManager.default.attributesOfItem(atPath: convertedURL.path)[.size] as? NSNumber)?.int64Value ?? track.byteCount
            return AudioTrack(
                id: track.id,
                url: convertedURL,
                fileName: convertedURL.lastPathComponent,
                fileExtension: "m4a",
                title: track.title,
                artist: track.artist,
                album: track.album,
                durationSeconds: track.durationSeconds,
                byteCount: byteCount,
                codecHint: "aac",
                compatibility: .ready,
                isSelected: track.isSelected,
                isDuplicateOnDevice: track.isDuplicateOnDevice
            )
        }
    }
}
