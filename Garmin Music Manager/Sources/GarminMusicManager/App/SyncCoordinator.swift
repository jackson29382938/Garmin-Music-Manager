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
        settings: SyncSettings,
        performance: PerformanceSettings = .default
    ) throws -> SyncPreview {
        let preparation = prepareTracks(tracks, settings: settings, performance: performance)
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
        deviceFiles: [DeviceFile],
        performance: PerformanceSettings = .default
    ) -> SyncPreview {
        let preparation = prepareTracks(tracks, settings: settings, performance: performance)
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
        performance: PerformanceSettings = .default,
        refreshAfter: Bool = true,
        progress: @escaping @Sendable (TransferProgressSnapshot) -> Void
    ) async -> MTPSyncResult {
        let skipped = plan.skippedCount
        let uploads = plan.uploads

        if plan.transferCount == 0 && uploads.isEmpty {
            progress(.phase(0.85, settings.writePlaylist ? "Building playlist…" : nil))
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
            progress(.phase(1, playlist.map { "Playlist “\($0)” ready." }))
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

        progress(.phase(0.05, "Preparing \(plan.transferCount) track(s) for Garmin…"))

        guard !uploads.isEmpty else {
            progress(.phase(1, nil))
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
        // Batch size matches Settings / PerformanceSettings (1…50), not a hard 20.
        let chunkSize = max(
            PerformanceSettings.uploadBatchRange.lowerBound,
            min(PerformanceSettings.uploadBatchRange.upperBound, performance.uploadBatchSize)
        )
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
        var succeededTrackIDs = Set<UUID>()
        var failedTrackIDSet = Set<UUID>()
        /// Pre-sync listing used for skip-identical object IDs (avoids a post-list).
        let preSyncDeviceFiles = deviceBrowser.files
        /// Upload index of the first file not fully processed (for remaining IDs).
        var nextUploadIndex = 0

        let transferBase = 0.08
        let transferSpan = settings.writePlaylist ? 0.78 : 0.88

        for chunk in chunks {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            let chunkBytes = Self.totalByteCount(of: chunk)
            let bytesBeforeChunk = completedBytes
            let chunkStartGlobal = nextUploadIndex

            let chunkStartIndex = completed
            progress(TransferProgressSnapshot(
                fraction: transferBase + transferSpan * (Double(bytesBeforeChunk) / Double(totalBytes)),
                message: "Uploading \(completed + 1)–\(min(completed + chunk.count, uploads.count)) of \(uploads.count)…",
                itemIndex: chunkStartIndex,
                itemCount: uploads.count,
                itemName: chunk.first?.displayName
            ))

            // Track the highest progress seen inside this chunk so a total failure
            // can still leave the bar at a truthful partial value (not a jump).
            let peakWithinChunk = PeakFraction()

            if let uploadResult = await deviceBrowser.upload(chunk, refreshAfter: false, onProgress: { event in
                peakWithinChunk.value = max(peakWithinChunk.value, event.overallFraction)
                let withinChunk = event.overallFraction * Double(max(chunkBytes, 1))
                let overallBytes = Double(bytesBeforeChunk) + withinChunk
                let fraction = transferBase + transferSpan * min(1, overallBytes / Double(totalBytes))
                let globalIndex = chunkStartIndex + event.itemIndex
                progress(TransferProgressSnapshot(
                    fraction: fraction,
                    message: event.displayMessage,
                    itemIndex: globalIndex,
                    itemCount: uploads.count,
                    itemName: event.itemName,
                    bytesTransferred: event.bytesTransferred,
                    bytesTotal: event.bytesTotal
                ))
            }) {
                completed += uploadResult.completedCount
                failedItems.append(contentsOf: uploadResult.failedItems)
                uploadedObjects.append(contentsOf: uploadResult.uploadedFiles)

                let classification = Self.classifyChunkResult(chunk: chunk, result: uploadResult)
                succeededTrackIDs.formUnion(classification.succeeded)
                failedTrackIDSet.formUnion(classification.failed)
                nextUploadIndex = chunkStartGlobal + classification.processedCount

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

                // Helper may return a partial result with a "Cancelled after…" message
                // instead of throwing — credit successes and stop further chunks.
                let resultLooksCancelled = uploadResult.message?
                    .localizedCaseInsensitiveContains("cancelled") == true
                if Task.isCancelled || resultLooksCancelled {
                    wasCancelled = true
                    break
                }
            } else {
                if Task.isCancelled {
                    wasCancelled = true
                    // Keep progress at last known peak; do not mark remaining as failed.
                    break
                }
                // Hard transport failure: entire chunk failed.
                failedItems.append(contentsOf: chunk.map(\.displayName))
                for file in chunk {
                    if let id = file.clientTrackUUID {
                        failedTrackIDSet.insert(id)
                    }
                }
                nextUploadIndex = chunkStartGlobal + chunk.count
            }
        }

        let remainingTrackIDs: [UUID]
        if nextUploadIndex < uploads.count {
            remainingTrackIDs = uploads[nextUploadIndex...].compactMap(\.clientTrackUUID)
                .filter { !succeededTrackIDs.contains($0) && !failedTrackIDSet.contains($0) }
        } else {
            remainingTrackIDs = []
        }

        // Fallback identity: plan items matched by display/path when client IDs missing.
        let failedNames = Set(failedItems)
        let failedPlanItems = plan.items.filter { item in
            guard item.action != .skipIdentical else { return false }
            if failedTrackIDSet.contains(item.track.id) { return true }
            if failedNames.contains(item.track.displayName) { return true }
            if let upload = item.uploadFile, failedNames.contains(upload.displayName) { return true }
            if failedNames.contains(item.targetRemotePath) { return true }
            return false
        }
        for item in failedPlanItems {
            failedTrackIDSet.insert(item.track.id)
        }
        // Drop successes from failed set if double-counted.
        failedTrackIDSet.subtract(succeededTrackIDs)

        let failedRemotePaths = Set(failedPlanItems.map { MTPSyncPlanner.normalizePath($0.targetRemotePath) })
        let failedKeys = failedRemotePaths.union(failedNames)
        let failedTrackIDs = Array(failedTrackIDSet)
        let replacedCount = plan.items.filter { item in
            guard item.action == .replace else { return false }
            if failedTrackIDSet.contains(item.track.id) { return false }
            if remainingTrackIDs.contains(item.track.id) { return false }
            let pathKey = MTPSyncPlanner.normalizePath(item.targetRemotePath)
            if failedRemotePaths.contains(pathKey) { return false }
            if failedNames.contains(item.track.displayName) { return false }
            return succeededTrackIDs.contains(item.track.id) || !wasCancelled
        }.count

        // Prefer object IDs from this transfer + the pre-sync listing so we can
        // build a native playlist without a multi-minute full re-list.
        // Also after cancel when some files already landed.
        var playlistNameResult: String?
        let remainingRemoteKeys = Set(
            uploads[nextUploadIndex...].map { MTPSyncPlanner.normalizePath($0.remotePath) }
        )
        let playlistExcludeKeys = failedKeys.union(remainingRemoteKeys)
        let shouldWritePlaylist = settings.writePlaylist
            && (completed > 0 || (!wasCancelled && plan.skippedCount > 0 && plan.transferCount == 0)
                || (!wasCancelled && plan.skippedCount > 0 && completed + failedItems.count >= plan.transferCount))
        if shouldWritePlaylist {
            let canSkipList = MTPPlaylistResolver.canResolveWithoutRefresh(
                plan: plan,
                failedDisplayNames: playlistExcludeKeys,
                deviceFiles: preSyncDeviceFiles,
                uploadedObjects: uploadedObjects
            )
            playlistNameResult = await maybeCreateMTPPlaylist(
                plan: plan,
                failedRemotePaths: playlistExcludeKeys,
                deviceBrowser: deviceBrowser,
                playlistName: playlistName,
                settings: settings,
                preSyncDeviceFiles: preSyncDeviceFiles,
                uploadedObjects: uploadedObjects,
                refreshFirst: !canSkipList,
                progress: progress
            )
        }

        // Refresh after any transfer activity (including cancel) so On Watch matches the device.
        if refreshAfter, completed > 0 || wasCancelled || !failedItems.isEmpty || plan.transferCount == 0 {
            progress(.phase(0.98, "Updating device browser…"))
            await deviceBrowser.refresh(force: true)
        }

        if wasCancelled {
            progress(TransferProgressSnapshot(
                fraction: transferBase + transferSpan * (Double(completedBytes) / Double(totalBytes)),
                message: "Cancelled after \(completed) of \(uploads.count) upload(s).",
                itemIndex: max(0, completed - 1),
                itemCount: uploads.count
            ))
        } else {
            progress(.phase(1, nil))
        }

        return MTPSyncResult(
            uploadedCount: completed,
            skippedCount: skipped,
            replacedCount: replacedCount,
            failedCount: failedItems.count,
            wasCancelled: wasCancelled,
            playlistName: playlistNameResult,
            failedItems: failedItems,
            failedTrackIDs: failedTrackIDs,
            remainingTrackIDs: remainingTrackIDs
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
        progress: @escaping @Sendable (TransferProgressSnapshot) -> Void
    ) async -> String? {
        guard settings.writePlaylist else { return nil }
        guard deviceBrowser.backendKind == .mtp else { return nil }

        if refreshFirst {
            progress(.phase(0.90, "Refreshing Garmin library…"))
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
            progress(.phase(0.90, "Refreshing Garmin library…"))
            await deviceBrowser.refresh(force: true)
            tracks = MTPPlaylistResolver.playlistTracks(
                plan: plan,
                failedDisplayNames: failedRemotePaths,
                deviceFiles: deviceBrowser.files,
                uploadedObjects: uploadedObjects
            )
        }
        guard !tracks.isEmpty else {
            progress(.phase(0.96, "Playlist skipped (no matching tracks on the Garmin yet)."))
            return nil
        }

        let cleanName = FileNameSanitizer.sanitizeFileName(playlistName)
        progress(.phase(0.95, "Writing playlist “\(cleanName)”…"))
        if let result = await deviceBrowser.createPlaylist(name: cleanName, tracks: tracks) {
            progress(.phase(0.98, result.message))
            return cleanName
        }
        if let error = deviceBrowser.lastError {
            progress(.phase(0.98, "Playlist not created: \(error)"))
        }
        return nil
    }

    func syncMounted(
        tracks: [AudioTrack],
        playlistName: String,
        destination: URL,
        settings: SyncSettings,
        performance: PerformanceSettings = .default,
        progress: @escaping @Sendable (TransferProgressSnapshot) -> Void
    ) async throws -> SyncResult {
        let preparation = prepareTracks(tracks, settings: settings, performance: performance)
        return try await syncService.sync(
            tracks: preparation.tracks,
            playlistName: playlistName,
            destination: destination,
            settings: settings,
            progress: progress
        )
    }

    /// Prepares tracks for transfer: ALAC/FLAC conversion when enabled, optional large-file compress.
    /// Failures are reported in `conversionFailures` instead of being silent.
    func prepareTracks(
        _ tracks: [AudioTrack],
        settings: SyncSettings,
        performance: PerformanceSettings = .default,
        conversion: ConversionSettings = .default
    ) -> TrackPreparationResult {
        let perf = performance.clamped
        let conv = conversion.clamped
        let largeThreshold = perf.largeFileByteThreshold
        let anyNeedsWork = tracks.contains { track in
            let format = settings.convertIncompatibleFormats
                && MusicCompatibilityEvaluator.needsConversion(ext: track.fileExtension, codecHint: track.codecHint)
            let large = largeThreshold.map { track.byteCount >= $0 } ?? false
            return format || large
        }
        guard anyNeedsWork else {
            return TrackPreparationResult(tracks: tracks, conversionFailures: [], convertedCount: 0)
        }

        if !audioConverter.isAvailable {
            var failures: [String] = []
            for track in tracks {
                let needsFormat = settings.convertIncompatibleFormats
                    && MusicCompatibilityEvaluator.needsConversion(ext: track.fileExtension, codecHint: track.codecHint)
                let needsLarge = largeThreshold.map { track.byteCount >= $0 } ?? false
                if needsFormat {
                    failures.append(
                        "Cannot convert \(track.displayName): ffmpeg is not installed (brew install ffmpeg)."
                    )
                } else if needsLarge {
                    failures.append(
                        "Cannot compress \(track.displayName): ffmpeg is not installed (brew install ffmpeg)."
                    )
                }
            }
            return TrackPreparationResult(tracks: tracks, conversionFailures: failures, convertedCount: 0)
        }

        let bitrate = perf.aacBitrateKbps
        var prepared: [AudioTrack] = []
        var failures: [String] = []
        var convertedCount = 0

        for track in tracks {
            let needsFormatConversion = settings.convertIncompatibleFormats
                && MusicCompatibilityEvaluator.needsConversion(ext: track.fileExtension, codecHint: track.codecHint)
            let needsSizeConversion = largeThreshold.map { track.byteCount >= $0 } ?? false
            guard needsFormatConversion || needsSizeConversion else {
                prepared.append(track)
                continue
            }

            do {
                let convertedURL = try audioConverter.convertToAAC(
                    source: track.url,
                    bitrateKbps: bitrate,
                    sampleRate: conv.aacSampleRate,
                    reuseExisting: conv.keepConversionCache
                )
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
                prepared.append(track)
            }
        }

        return TrackPreparationResult(tracks: prepared, conversionFailures: failures, convertedCount: convertedCount)
    }

    /// Backward-compatible wrapper used by older call sites.
    func preparedTracks(
        _ tracks: [AudioTrack],
        settings: SyncSettings,
        performance: PerformanceSettings = .default,
        conversion: ConversionSettings = .default
    ) -> [AudioTrack] {
        prepareTracks(tracks, settings: settings, performance: performance, conversion: conversion).tracks
    }

    // MARK: - Chunk identity helpers

    private struct ChunkClassification {
        var succeeded: Set<UUID>
        var failed: Set<UUID>
        /// Number of leading files in the chunk that were attempted (success or fail).
        var processedCount: Int
    }

    /// Maps helper upload results back to stable client track IDs within one chunk.
    private static func classifyChunkResult(
        chunk: [DeviceUploadFile],
        result: DeviceFileOperationResult
    ) -> ChunkClassification {
        let failedNames = Set(result.failedItems)
        let uploadedByName = Set(result.uploadedFiles.map(\.displayName))
        let uploadedByPath = Set(result.uploadedFiles.map { MTPSyncPlanner.normalizePath($0.remotePath) })

        var succeeded = Set<UUID>()
        var failed = Set<UUID>()
        var processed = 0

        for file in chunk {
            let pathKey = MTPSyncPlanner.normalizePath(file.remotePath)
            let isFailed = failedNames.contains(file.displayName)
                || failedNames.contains(file.remotePath)
                || failedNames.contains(pathKey)
            let isUploaded = uploadedByName.contains(file.displayName)
                || uploadedByPath.contains(pathKey)

            if isFailed {
                if let id = file.clientTrackUUID { failed.insert(id) }
                processed += 1
            } else if isUploaded {
                if let id = file.clientTrackUUID { succeeded.insert(id) }
                processed += 1
            } else {
                // Unmentioned file — treat as not attempted (cancel / early stop).
                // Remaining files in the chunk are also unprocessed.
                break
            }
        }

        return ChunkClassification(succeeded: succeeded, failed: failed, processedCount: processed)
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
