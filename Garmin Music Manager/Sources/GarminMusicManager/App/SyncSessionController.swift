import Foundation
import GarminMusicCore

/// Owns mounted + MTP sync execution (preview building, progress, cancellation).
/// UI state (`isSyncing`, `syncProgress`, etc.) stays on `AppModel`.
@MainActor
final class SyncSessionController {
    private let syncCoordinator = SyncCoordinator()
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = UUID()

    var isRunning: Bool { syncTask != nil }

    func cancel() {
        syncTask?.cancel()
        syncTask = nil
        syncGeneration = UUID()
        Task { await MTPHelperClient.cancelInFlightHelper() }
    }

    func buildPreview(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        activeDestination: URL?,
        deviceFiles: [DeviceFile],
        mtpReady: Bool
    ) throws -> SyncPreview {
        if let destination = activeDestination {
            return try syncCoordinator.buildMountedPreview(
                tracks: tracks,
                playlistName: playlistName,
                destination: destination,
                settings: settings
            )
        }
        guard mtpReady else {
            throw SyncSessionError.mtpNotReady
        }
        return syncCoordinator.buildMTPPreview(
            tracks: tracks,
            playlistName: playlistName,
            settings: settings,
            deviceFiles: deviceFiles
        )
    }

    func prepareTracks(_ tracks: [AudioTrack], settings: SyncSettings) -> TrackPreparationResult {
        syncCoordinator.prepareTracks(tracks, settings: settings)
    }

    func preparedTracks(_ tracks: [AudioTrack], settings: SyncSettings) -> [AudioTrack] {
        syncCoordinator.preparedTracks(tracks, settings: settings)
    }

    func executeMTPPlan(
        _ plan: MTPSyncPlan,
        deviceBrowser: DeviceBrowserStore,
        playlistName: String,
        settings: SyncSettings,
        refreshAfter: Bool = true,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async -> MTPSyncResult {
        await syncCoordinator.executeMTPPlan(
            plan,
            deviceBrowser: deviceBrowser,
            playlistName: playlistName,
            settings: settings,
            refreshAfter: refreshAfter,
            progress: progress
        )
    }

    /// Runs a mounted-folder or MTP sync.
    func run(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        activeDestination: URL?,
        mtpReady: Bool = true,
        mtpNotReadyMessage: String = "MTP support is not ready.",
        deviceBrowser: DeviceBrowserStore,
        configureMTP: @escaping () -> Void,
        onProgress: @escaping @MainActor (Double, String?) -> Void,
        onLog: @escaping @MainActor (String) -> Void,
        onMountedComplete: @escaping @MainActor (URL) -> Void,
        onMTPComplete: @escaping @MainActor (MTPSyncResult) -> Void
    ) async {
        syncTask?.cancel()
        guard !tracks.isEmpty else {
            onLog("Nothing to sync.")
            return
        }

        if let destination = activeDestination {
            await runMounted(
                tracks: tracks,
                playlistName: playlistName,
                settings: settings,
                destination: destination,
                onProgress: onProgress,
                onLog: onLog,
                onComplete: onMountedComplete
            )
            return
        }

        guard mtpReady else {
            onLog(mtpNotReadyMessage)
            return
        }

        await runMTP(
            tracks: tracks,
            playlistName: playlistName,
            settings: settings,
            deviceBrowser: deviceBrowser,
            configureMTP: configureMTP,
            onProgress: onProgress,
            onLog: onLog,
            onComplete: onMTPComplete
        )
    }

    private func runMounted(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        destination: URL,
        onProgress: @escaping @MainActor (Double, String?) -> Void,
        onLog: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (URL) -> Void
    ) async {
        onLog("Starting sync to \(destination.path)")
        let generation = UUID()
        syncGeneration = generation
        let task = Task { @MainActor in
            do {
                let preparation = syncCoordinator.prepareTracks(tracks, settings: settings)
                self.logPreparation(preparation, onLog: onLog)
                let result = try await syncCoordinator.syncMounted(
                    tracks: preparation.tracks,
                    playlistName: playlistName,
                    destination: destination,
                    settings: settings
                ) { progress, message in
                    Task { @MainActor in
                        onProgress(progress, message)
                    }
                }
                onLog("Sync complete: copied \(result.copiedCount), skipped \(result.skippedCount), replaced \(result.replacedCount).")
                if settings.writePlaylist {
                    onLog("Playlist: \(result.playlistURL.lastPathComponent)")
                }
                onComplete(destination)
            } catch is CancellationError {
                onLog("Sync cancelled.")
            } catch {
                onLog("Sync failed: \(error.localizedDescription)")
            }
        }
        syncTask = task
        await task.value
        if syncGeneration == generation {
            syncTask = nil
        }
    }

    private func runMTP(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        deviceBrowser: DeviceBrowserStore,
        configureMTP: @escaping () -> Void,
        onProgress: @escaping @MainActor (Double, String?) -> Void,
        onLog: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (MTPSyncResult) -> Void
    ) async {
        onLog("Starting MTP sync to Garmin watch")
        let generation = UUID()
        syncGeneration = generation
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                configureMTP()
                onProgress(0.05, nil)
                if deviceBrowser.hasFreshListing {
                    onLog("Using recent Garmin library listing for sync plan…")
                } else {
                    onLog("Refreshing Garmin library before sync…")
                    await deviceBrowser.refresh(force: true)
                }
                try Task.checkCancellation()

                let preparation = syncCoordinator.prepareTracks(tracks, settings: settings)
                self.logPreparation(preparation, onLog: onLog)

                let plan = MTPSyncPlanner.buildPlan(
                    tracks: preparation.tracks,
                    playlistName: playlistName,
                    settings: settings,
                    deviceFiles: deviceBrowser.files
                )

                // Always execute so native playlist create/update runs for skip-all cases.
                try Task.checkCancellation()
                let result = await syncCoordinator.executeMTPPlan(
                    plan,
                    deviceBrowser: deviceBrowser,
                    playlistName: playlistName,
                    settings: settings,
                    refreshAfter: true
                ) { progress, message in
                    Task { @MainActor in
                        onProgress(progress, message)
                    }
                }

                if result.wasCancelled {
                    onLog("MTP sync cancelled after sending \(result.uploadedCount) track(s)\(result.failedCount > 0 ? " (\(result.failedCount) failed before cancel)" : "").")
                } else if plan.transferCount == 0 {
                    onLog("MTP sync complete: all \(result.skippedCount) selected track(s) already on the Garmin.")
                } else if result.failedCount > 0 {
                    onLog("MTP sync partially complete: sent \(result.uploadedCount), skipped \(result.skippedCount), replaced \(result.replacedCount), \(result.failedCount) failed.")
                    onLog("Use Retry Failed to re-send only the tracks that did not transfer.")
                } else {
                    onLog("MTP sync complete: sent \(result.uploadedCount), skipped \(result.skippedCount), replaced \(result.replacedCount).")
                }
                if let playlistName = result.playlistName {
                    onLog("Playlist on Garmin: \(playlistName)")
                }
                onComplete(result)
            } catch is CancellationError {
                onLog("MTP sync cancelled.")
            } catch {
                onLog("MTP sync failed: \(error.localizedDescription)")
            }
        }
        syncTask = task
        await task.value
        if syncGeneration == generation {
            syncTask = nil
        }
    }

    private func logPreparation(
        _ preparation: TrackPreparationResult,
        onLog: (String) -> Void
    ) {
        if preparation.convertedCount > 0 {
            onLog("Converted \(preparation.convertedCount) track(s) to AAC for Garmin.")
        }
        for failure in preparation.conversionFailures {
            onLog(failure)
        }
    }
}

enum SyncSessionError: LocalizedError {
    case mtpNotReady

    var errorDescription: String? {
        switch self {
        case .mtpNotReady:
            return "MTP support is not ready."
        }
    }
}
