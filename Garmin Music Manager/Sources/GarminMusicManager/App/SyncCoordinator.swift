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
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async -> MTPSyncResult {
        let skipped = plan.skippedCount
        if plan.transferCount == 0 {
            progress(1, "All \(skipped) track(s) already on the Garmin.")
            return MTPSyncResult(uploadedCount: 0, skippedCount: skipped, replacedCount: 0, failedCount: 0)
        }

        progress(0.05, "Preparing \(plan.transferCount) track(s) for Garmin…")

        // Replacements are handled per item by the helper: it deletes the old
        // copy immediately before uploading its replacement.
        let uploads = plan.uploads
        guard !uploads.isEmpty else {
            progress(1, nil)
            return MTPSyncResult(uploadedCount: 0, skippedCount: skipped, replacedCount: 0, failedCount: 0)
        }

        // Chunk uploads for progress + partial recovery. The persistent helper keeps
        // the MTP session warm between chunks, so this is not a cold re-open each time.
        let chunkSize = MTPHelperClient.uploadChunkSize
        let chunks: [[DeviceUploadFile]] = stride(from: 0, to: uploads.count, by: chunkSize).map {
            Array(uploads[$0..<min($0 + chunkSize, uploads.count)])
        }

        var completed = 0
        var failedItems: [String] = []

        for (index, chunk) in chunks.enumerated() {
            try? Task.checkCancellation()
            if Task.isCancelled {
                break
            }
            let base = 0.1
            let span = 0.85
            let chunkStart = base + span * (Double(index) / Double(max(chunks.count, 1)))
            progress(
                chunkStart,
                "Uploading \(completed + 1)–\(min(completed + chunk.count, uploads.count)) of \(uploads.count) to Garmin…"
            )

            if let uploadResult = await deviceBrowser.upload(chunk, refreshAfter: false) {
                completed += uploadResult.completedCount
                failedItems.append(contentsOf: uploadResult.failedItems)
            } else {
                failedItems.append(contentsOf: chunk.map(\.displayName))
            }
        }

        progress(0.97, "Finishing MTP transfer…")
        // One refresh at the end (warm session) instead of after every chunk.
        await deviceBrowser.refresh(force: true)
        progress(1, nil)

        let failedNames = Set(failedItems)
        let replacedCount = plan.items.filter {
            $0.action == .replace && !failedNames.contains($0.track.displayName)
        }.count

        return MTPSyncResult(
            uploadedCount: completed,
            skippedCount: skipped,
            replacedCount: replacedCount,
            failedCount: failedItems.count
        )
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
