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
        performance: PerformanceSettings = .default,
        activeDestination: URL?,
        deviceFiles: [DeviceFile],
        mtpReady: Bool
    ) throws -> SyncPreview {
        if let destination = activeDestination {
            return try syncCoordinator.buildMountedPreview(
                tracks: tracks,
                playlistName: playlistName,
                destination: destination,
                settings: settings,
                performance: performance
            )
        }
        guard mtpReady else {
            throw SyncSessionError.mtpNotReady
        }
        return syncCoordinator.buildMTPPreview(
            tracks: tracks,
            playlistName: playlistName,
            settings: settings,
            deviceFiles: deviceFiles,
            performance: performance
        )
    }

    func prepareTracks(
        _ tracks: [AudioTrack],
        settings: SyncSettings,
        performance: PerformanceSettings = .default,
        conversion: ConversionSettings = .default
    ) -> TrackPreparationResult {
        syncCoordinator.prepareTracks(
            tracks,
            settings: settings,
            performance: performance,
            conversion: conversion
        )
    }

    func preparedTracks(
        _ tracks: [AudioTrack],
        settings: SyncSettings,
        performance: PerformanceSettings = .default,
        conversion: ConversionSettings = .default
    ) -> [AudioTrack] {
        syncCoordinator.preparedTracks(
            tracks,
            settings: settings,
            performance: performance,
            conversion: conversion
        )
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
        await syncCoordinator.executeMTPPlan(
            plan,
            deviceBrowser: deviceBrowser,
            playlistName: playlistName,
            settings: settings,
            performance: performance,
            refreshAfter: refreshAfter,
            progress: progress
        )
    }

    /// Runs a mounted-folder or MTP sync.
    func run(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        performance: PerformanceSettings = .default,
        conversion: ConversionSettings = .default,
        refreshAfterSend: Bool = true,
        activeDestination: URL?,
        mtpReady: Bool = true,
        mtpNotReadyMessage: String = "MTP support is not ready.",
        deviceBrowser: DeviceBrowserStore,
        configureMTP: @escaping () -> Void,
        onProgress: @escaping @MainActor (TransferProgressSnapshot) -> Void,
        onLog: @escaping @MainActor (String) -> Void,
        onMountedComplete: @escaping @MainActor (SyncResult) -> Void,
        onMTPComplete: @escaping @MainActor (MTPSyncResult) -> Void,
        onCancelled: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
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
                performance: performance,
                conversion: conversion,
                destination: destination,
                onProgress: onProgress,
                onLog: onLog,
                onComplete: onMountedComplete,
                onCancelled: onCancelled,
                onFailed: onFailed
            )
            return
        }

        guard mtpReady else {
            onLog(mtpNotReadyMessage)
            onFailed(SyncSessionError.mtpNotReady)
            return
        }

        await runMTP(
            tracks: tracks,
            playlistName: playlistName,
            settings: settings,
            performance: performance,
            conversion: conversion,
            refreshAfterSend: refreshAfterSend,
            deviceBrowser: deviceBrowser,
            configureMTP: configureMTP,
            onProgress: onProgress,
            onLog: onLog,
            onComplete: onMTPComplete,
            onCancelled: onCancelled,
            onFailed: onFailed
        )
    }

    private func runMounted(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        performance: PerformanceSettings,
        conversion: ConversionSettings,
        destination: URL,
        onProgress: @escaping @MainActor (TransferProgressSnapshot) -> Void,
        onLog: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (SyncResult) -> Void,
        onCancelled: @escaping @MainActor () -> Void,
        onFailed: @escaping @MainActor (Error) -> Void
    ) async {
        onLog("Starting sync to \(destination.path)")
        let generation = UUID()
        syncGeneration = generation
        let task = Task { @MainActor in
            do {
                let preparation = syncCoordinator.prepareTracks(
                    tracks,
                    settings: settings,
                    performance: performance,
                    conversion: conversion
                )
                self.logPreparation(preparation, onLog: onLog)
                let result = try await syncCoordinator.syncMounted(
                    tracks: preparation.tracks,
                    playlistName: playlistName,
                    destination: destination,
                    settings: settings,
                    performance: performance
                ) { snapshot in
                    Task { @MainActor in
                        onProgress(snapshot)
                    }
                }
                onLog("Sync complete: copied \(result.copiedCount), skipped \(result.skippedCount), replaced \(result.replacedCount).")
                if settings.writePlaylist {
                    onLog("Playlist: \(result.playlistURL.lastPathComponent)")
                }
                onComplete(result)
            } catch is CancellationError {
                onLog("Sync cancelled.")
                onCancelled()
            } catch {
                onLog("Sync failed: \(error.localizedDescription)")
                onFailed(error)
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
        performance: PerformanceSettings,
        conversion: ConversionSettings,
        refreshAfterSend: Bool,
        deviceBrowser: DeviceBrowserStore,
        configureMTP: @escaping () -> Void,
        onProgress: @escaping @MainActor (TransferProgressSnapshot) -> Void,
        onLog: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (MTPSyncResult) -> Void,
        onCancelled: @escaping @MainActor () -> Void,
        onFailed: @escaping @MainActor (Error) -> Void
    ) async {
        onLog("Starting MTP sync to Garmin watch")
        let generation = UUID()
        syncGeneration = generation
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                configureMTP()
                onProgress(.phase(0.05, "Connecting to watch…"))
                if performance.forceRefreshBeforeSync || !deviceBrowser.hasFreshListing {
                    onLog("Refreshing Garmin library before sync…")
                    onProgress(.phase(0.06, "Refreshing Garmin library…"))
                    await deviceBrowser.refresh(force: true)
                } else {
                    onLog("Using recent Garmin library listing for sync plan…")
                }
                try Task.checkCancellation()

                let preparation = syncCoordinator.prepareTracks(
                    tracks,
                    settings: settings,
                    performance: performance,
                    conversion: conversion
                )
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
                    performance: performance,
                    refreshAfter: refreshAfterSend
                ) { snapshot in
                    Task { @MainActor in
                        onProgress(snapshot)
                    }
                }

                if result.wasCancelled {
                    if result.uploadedCount > 0 {
                        onLog("MTP sync cancelled after sending \(result.uploadedCount) track(s)\(result.failedCount > 0 ? " (\(result.failedCount) failed before cancel)" : ""). Successful uploads were kept on the watch.")
                        if result.failedCount > 0 {
                            onLog("Use Retry / continue send for failed or not-yet-attempted tracks.")
                        }
                    } else {
                        onLog("MTP sync cancelled before any track finished uploading.")
                    }
                } else if plan.transferCount == 0 {
                    onLog("MTP sync complete: all \(result.skippedCount) selected track(s) already on the Garmin.")
                } else if result.failedCount > 0 {
                    onLog("MTP sync partially complete: sent \(result.uploadedCount), skipped \(result.skippedCount), replaced \(result.replacedCount), \(result.failedCount) failed.")
                    onLog("Use Retry / continue send for tracks that did not transfer.")
                } else {
                    onLog("MTP sync complete: sent \(result.uploadedCount), skipped \(result.skippedCount), replaced \(result.replacedCount).")
                }
                if let playlistName = result.playlistName {
                    onLog("Playlist on Garmin: \(playlistName)")
                }
                onComplete(result)
            } catch is CancellationError {
                onLog("MTP sync cancelled.")
                onCancelled()
            } catch {
                onLog("MTP sync failed: \(error.localizedDescription)")
                onFailed(error)
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
