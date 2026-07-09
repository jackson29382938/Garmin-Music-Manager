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
        let preparation = prepareTracks(tracks, settings: settings)
        return try syncService.buildPreview(
            tracks: preparation.tracks,
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
        let preparation = prepareTracks(tracks, settings: settings)
        let plan = MTPSyncPlanner.buildPlan(
            tracks: preparation.tracks,
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
            let preSync = deviceBrowser.files
            let canSkipList = MTPPlaylistResolver.canResolveWithoutRefresh(
                plan: plan,
                failedDisplayNames: [],
                deviceFiles: preSync,
                uploadedObjects: []
            )
            let playlist = await maybeCreateMTPPlaylist(
                plan: plan,
                failedRemotePaths: [],
                deviceBrowser: deviceBrowser,
                playlistName: playlistName,
                settings: settings,
                preSyncDeviceFiles: preSync,
                uploadedObjects: [],
                refreshFirst: !canSkipList && settings.writePlaylist,
                progress: progress
            )
            if refreshAfter {
                await deviceBrowser.refresh(force: true)
            }
            progress(1, playlist.map { "Playlist “\($0)” ready." })
            return MTPSyncResult(
                uploadedCount: 0,
                skippedCount: skipped,
                replacedCount: 0,
                failedCount: 0,
                playlistName: playlist,
                failedItems: [],
                failedTrackIDs: []
            )
        }

        progress(0.05, "Preparing \(plan.transferCount) track(s) for Garmin…")

        guard !uploads.isEmpty else {
            progress(1, nil)
            return MTPSyncResult(
                uploadedCount: 0,
                skippedCount: skipped,
                replacedCount: 0,
                failedCount: 0,
                failedTrackIDs: []
            )
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
        var uploadedObjects: [DeviceUploadedObject] = []
        /// Bytes known to have finished successfully (not speculative chunk totals).
        var completedBytes: Int64 = 0
        var wasCancelled = false
        /// Pre-sync listing used for skip-identical object IDs (avoids a post-list).
        let preSyncDeviceFiles = deviceBrowser.files

        let transferBase = 0.08
        let transferSpan = settings.writePlaylist ? 0.78 : 0.88

        for chunk in chunks {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            let chunkBytes = Self.totalByteCount(of: chunk)
            let bytesBeforeChunk = completedBytes

            progress(
                transferBase + transferSpan * (Double(bytesBeforeChunk) / Double(totalBytes)),
                "Uploading \(completed + 1)–\(min(completed + chunk.count, uploads.count)) of \(uploads.count)…"
            )

            // Track the highest progress seen inside this chunk so a total failure
            // can still leave the bar at a truthful partial value (not a jump).
            let peakWithinChunk = PeakFraction()

            if let uploadResult = await deviceBrowser.upload(chunk, refreshAfter: false, onProgress: { event in
                peakWithinChunk.value = max(peakWithinChunk.value, event.overallFraction)
                let withinChunk = event.overallFraction * Double(max(chunkBytes, 1))
                let overallBytes = Double(bytesBeforeChunk) + withinChunk
                let fraction = transferBase + transferSpan * min(1, overallBytes / Double(totalBytes))
                progress(fraction, event.displayMessage)
            }) {
                if Task.isCancelled {
                    wasCancelled = true
                }

                completed += uploadResult.completedCount
                failedItems.append(contentsOf: uploadResult.failedItems)
                uploadedObjects.append(contentsOf: uploadResult.uploadedFiles)

                // Advance by successfully transferred bytes only. If the helper
                // reports partial success, estimate success share from counts.
                let successBytes = Self.successfulByteCount(
                    chunk: chunk,
                    completedCount: uploadResult.completedCount,
                    failedItems: uploadResult.failedItems,
                    chunkBytes: chunkBytes,
                    peakFraction: peakWithinChunk.value
                )
                completedBytes += successBytes
            } else {
                if Task.isCancelled {
                    wasCancelled = true
                    // Keep progress at last known peak; do not mark remaining as failed.
                    break
                }
                failedItems.append(contentsOf: chunk.map(\.displayName))
                // Full chunk failure: no byte credit.
            }
        }

        let failedNames = Set(failedItems)
        let failedPlanItems = plan.items.filter { item in
            guard item.action != .skipIdentical else { return false }
            if failedNames.contains(item.track.displayName) { return true }
            if let upload = item.uploadFile, failedNames.contains(upload.displayName) { return true }
            if failedNames.contains(item.targetRemotePath) { return true }
            return false
        }
        let failedRemotePaths = Set(failedPlanItems.map { MTPSyncPlanner.normalizePath($0.targetRemotePath) })
        let failedKeys = failedRemotePaths.union(failedNames)
        let failedTrackIDs = failedPlanItems.map(\.track.id)
        let replacedCount = plan.items.filter { item in
            guard item.action == .replace else { return false }
            let pathKey = MTPSyncPlanner.normalizePath(item.targetRemotePath)
            if failedRemotePaths.contains(pathKey) { return false }
            if failedNames.contains(item.track.displayName) { return false }
            return true
        }.count

        if wasCancelled {
            progress(
                transferBase + transferSpan * (Double(completedBytes) / Double(totalBytes)),
                "Cancelled after \(completed) of \(uploads.count) upload(s)."
            )
            return MTPSyncResult(
                uploadedCount: completed,
                skippedCount: skipped,
                replacedCount: replacedCount,
                failedCount: failedItems.count,
                wasCancelled: true,
                playlistName: nil,
                failedItems: failedItems,
                failedTrackIDs: failedTrackIDs
            )
        }

        // Prefer object IDs from this transfer + the pre-sync listing so we can
        // build a native playlist without a multi-minute full re-list.
        let canSkipList = MTPPlaylistResolver.canResolveWithoutRefresh(
            plan: plan,
            failedDisplayNames: failedKeys,
            deviceFiles: preSyncDeviceFiles,
            uploadedObjects: uploadedObjects
        )

        let playlist = await maybeCreateMTPPlaylist(
            plan: plan,
            failedRemotePaths: failedKeys,
            deviceBrowser: deviceBrowser,
            playlistName: playlistName,
            settings: settings,
            preSyncDeviceFiles: preSyncDeviceFiles,
            uploadedObjects: uploadedObjects,
            refreshFirst: !canSkipList && settings.writePlaylist,
            progress: progress
        )

        // At most one UI refresh after the transfer (optional).
        if refreshAfter {
            progress(0.98, "Updating device browser…")
            await deviceBrowser.refresh(force: true)
        }

        progress(1, nil)

        return MTPSyncResult(
            uploadedCount: completed,
            skippedCount: skipped,
            replacedCount: replacedCount,
            failedCount: failedItems.count,
            wasCancelled: false,
            playlistName: playlist,
            failedItems: failedItems,
            failedTrackIDs: failedTrackIDs
        )
    }

    private func maybeCreateMTPPlaylist(
        plan: MTPSyncPlan,
        failedRemotePaths: Set<String>,
        deviceBrowser: DeviceBrowserStore,
        playlistName: String,
        settings: SyncSettings,
        preSyncDeviceFiles: [DeviceFile] = [],
        uploadedObjects: [DeviceUploadedObject] = [],
        refreshFirst: Bool,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async -> String? {
        guard settings.writePlaylist else { return nil }
        guard deviceBrowser.backendKind == .mtp else { return nil }

        if refreshFirst {
            progress(0.90, "Refreshing Garmin library…")
            await deviceBrowser.refresh(force: true)
        }

        let listing = refreshFirst ? deviceBrowser.files : preSyncDeviceFiles
        var tracks = MTPPlaylistResolver.playlistTracks(
            plan: plan,
            failedDisplayNames: failedRemotePaths,
            deviceFiles: listing,
            uploadedObjects: uploadedObjects
        )
        // Last resort: if we still cannot resolve and have not refreshed, try once.
        if tracks.isEmpty, !refreshFirst {
            progress(0.90, "Refreshing Garmin library…")
            await deviceBrowser.refresh(force: true)
            tracks = MTPPlaylistResolver.playlistTracks(
                plan: plan,
                failedDisplayNames: failedRemotePaths,
                deviceFiles: deviceBrowser.files,
                uploadedObjects: uploadedObjects
            )
        }
        guard !tracks.isEmpty else {
            progress(0.96, "Playlist skipped (no matching tracks on the Garmin yet).")
            return nil
        }

        let cleanName = FileNameSanitizer.sanitizeFileName(playlistName)
        progress(0.95, "Writing playlist “\(cleanName)”…")
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
        let preparation = prepareTracks(tracks, settings: settings)
        return try await syncService.sync(
            tracks: preparation.tracks,
            playlistName: playlistName,
            destination: destination,
            settings: settings,
            progress: progress
        )
    }

    /// Prepares tracks for transfer, converting ALAC/FLAC when enabled.
    /// Failures are reported in `conversionFailures` instead of being silent.
    func prepareTracks(_ tracks: [AudioTrack], settings: SyncSettings) -> TrackPreparationResult {
        guard settings.convertIncompatibleFormats else {
            return TrackPreparationResult(tracks: tracks, conversionFailures: [], convertedCount: 0)
        }

        guard audioConverter.isAvailable else {
            let needing = tracks.filter {
                MusicCompatibilityEvaluator.needsConversion(ext: $0.fileExtension, codecHint: $0.codecHint)
            }
            let failures = needing.map {
                "Cannot convert \($0.displayName): ffmpeg is not installed (brew install ffmpeg)."
            }
            return TrackPreparationResult(tracks: tracks, conversionFailures: failures, convertedCount: 0)
        }

        var prepared: [AudioTrack] = []
        var failures: [String] = []
        var convertedCount = 0

        for track in tracks {
            guard MusicCompatibilityEvaluator.needsConversion(ext: track.fileExtension, codecHint: track.codecHint) else {
                prepared.append(track)
                continue
            }

            do {
                let convertedURL = try audioConverter.convertToAAC(source: track.url)
                let byteCount = (try? FileManager.default.attributesOfItem(atPath: convertedURL.path)[.size] as? NSNumber)?.int64Value
                    ?? track.byteCount
                prepared.append(AudioTrack(
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
                ))
                convertedCount += 1
            } catch {
                failures.append("Conversion failed for \(track.displayName): \(error.localizedDescription)")
                // Keep original so planner/UI can still show it as blocked/incompatible.
                prepared.append(track)
            }
        }

        return TrackPreparationResult(tracks: prepared, conversionFailures: failures, convertedCount: convertedCount)
    }

    /// Backward-compatible wrapper used by older call sites.
    func preparedTracks(_ tracks: [AudioTrack], settings: SyncSettings) -> [AudioTrack] {
        prepareTracks(tracks, settings: settings).tracks
    }

    // MARK: - Byte accounting helpers

    private static func totalByteCount(of files: [DeviceUploadFile]) -> Int64 {
        files.reduce(Int64(0)) { partial, file in
            partial + max(fileSize(atPath: file.localPath), 0)
        }
    }

    private static func fileSize(atPath path: String) -> Int64 {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
    }

    /// Credits only successful work toward overall progress.
    private static func successfulByteCount(
        chunk: [DeviceUploadFile],
        completedCount: Int,
        failedItems: [String],
        chunkBytes: Int64,
        peakFraction: Double
    ) -> Int64 {
        if failedItems.isEmpty, completedCount >= chunk.count {
            return chunkBytes
        }

        let failedNames = Set(failedItems)
        let succeeded = chunk.filter { !failedNames.contains($0.displayName) }
        if !succeeded.isEmpty {
            let credited = totalByteCount(of: succeeded)
            if credited > 0 { return credited }
        }

        // Partial helper result without per-file sizes: use peak progress fraction.
        if completedCount > 0, chunk.count > 0 {
            let ratio = min(1, max(0, Double(completedCount) / Double(chunk.count)))
            return Int64(Double(chunkBytes) * ratio)
        }

        // Total failure: no credit (peakFraction ignored so the bar doesn't jump).
        _ = peakFraction
        return 0
    }
}

/// Mutable peak fraction box for progress callbacks (@Sendable closures).
private final class PeakFraction: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double = 0

    var value: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}
