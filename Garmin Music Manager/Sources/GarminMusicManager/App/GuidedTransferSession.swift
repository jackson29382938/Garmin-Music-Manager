import AppKit
import Foundation
import GarminMusicCore

/// Owns Guided Transfer wizard state, deep library scan, analysis, and execution.
@MainActor
final class GuidedTransferSession: ObservableObject {
    @Published var step: GuidedWizardStep = .pairWatch
    @Published var mode: GuidedTransferMode?
    @Published var plan: GuidedTransferPlan?
    @Published var summary: GuidedTransferSummary?
    @Published var analysisProgress: String = ""
    @Published var isAnalyzing = false
    @Published var isTransferring = false
    @Published var transferProgress: TransferProgressSnapshot?
    @Published var errorMessage: String?
    @Published var showDetails = false
    @Published var showConflicts = true
    @Published private(set) var importDestinationPath: String?
    @Published var enabledScanSources: Set<GuidedLibraryScanSource> = [
        .transferQueue, .musicFolder, .appleMusicLocal
    ]
    @Published private(set) var catalogStats = GuidedCatalogStats()
    /// Scanned/merged Mac catalog used for planning (may be larger than Transfer queue).
    @Published private(set) var macCatalog: [AudioTrack] = []

    private let scanner = MusicScanner()
    private let appleMusic = AppleMusicLibrary()
    private var analysisTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var transferStartedAt: Date?

    /// Soft cap for Music-folder files so analysis stays responsive.
    static let musicFolderScanCap = 4_000

    // MARK: - Navigation

    func cancelAnalysisOnly() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
    }

    func reset() {
        analysisTask?.cancel()
        transferTask?.cancel()
        analysisTask = nil
        transferTask = nil
        step = .pairWatch
        mode = nil
        plan = nil
        summary = nil
        analysisProgress = ""
        isAnalyzing = false
        isTransferring = false
        transferProgress = nil
        errorMessage = nil
        showDetails = false
        showConflicts = true
        importDestinationPath = nil
        transferStartedAt = nil
        macCatalog = []
        catalogStats = GuidedCatalogStats()
    }

    func goBack(model: AppModel) {
        switch step {
        case .pairWatch:
            break
        case .chooseMode:
            step = .pairWatch
        case .analyze, .reviewPlan:
            analysisTask?.cancel()
            isAnalyzing = false
            plan = nil
            step = .chooseMode
        case .confirmPlan:
            step = .reviewPlan
        case .transferProgress:
            break
        case .completeSummary, .errorRecovery:
            reset()
        }
    }

    func cancelWizard(model: AppModel) {
        if isTransferring {
            model.cancelSync()
            model.cancelDeviceOperation()
        }
        analysisTask?.cancel()
        transferTask?.cancel()
        reset()
    }

    func pairIsReady(model: AppModel) -> Bool {
        model.destinationIsReady
    }

    func continueFromPair(model: AppModel) {
        guard pairIsReady(model: model) else {
            errorMessage = "Connect your Garmin (USB data cable), unlock it, then Refresh."
            return
        }
        errorMessage = nil
        step = .chooseMode
    }

    func selectMode(_ mode: GuidedTransferMode, model: AppModel) {
        self.mode = mode
        plan = nil
        summary = nil
        step = .analyze
        startAnalysis(model: model)
    }

    func toggleScanSource(_ source: GuidedLibraryScanSource) {
        if enabledScanSources.contains(source) {
            // Keep at least one source when sending to watch / both.
            if enabledScanSources.count > 1 {
                enabledScanSources.remove(source)
            }
        } else {
            enabledScanSources.insert(source)
        }
    }

    // MARK: - Analysis

    func startAnalysis(model: AppModel) {
        analysisTask?.cancel()
        guard let mode else { return }
        isAnalyzing = true
        analysisProgress = "Preparing…"
        errorMessage = nil

        analysisTask = Task { @MainActor in
            defer { isAnalyzing = false }
            do {
                try Task.checkCancellation()
                analysisProgress = "Refreshing watch library…"
                await ensureDeviceListing(model: model)

                try Task.checkCancellation()
                if mode == .toWatch || mode == .bothWays {
                    analysisProgress = "Scanning Mac libraries…"
                    let (catalog, stats) = await gatherMacCatalog(model: model)
                    macCatalog = catalog
                    catalogStats = stats
                } else {
                    // Still index queue for “already on Mac” comparison.
                    macCatalog = model.tracks
                    catalogStats = GuidedCatalogStats(
                        queueCount: model.tracks.count,
                        uniqueTracks: model.tracks.count
                    )
                }

                try Task.checkCancellation()
                analysisProgress = "Comparing libraries…"
                plan = buildPlan(mode: mode, model: model, macTracks: macCatalog, stats: catalogStats)
                analysisProgress = "Plan ready."
                step = .reviewPlan
            } catch is CancellationError {
                analysisProgress = "Analysis cancelled."
            } catch {
                errorMessage = error.localizedDescription
                step = .errorRecovery
            }
        }
    }

    private func ensureDeviceListing(model: AppModel) async {
        if model.canAttemptMTP {
            if !model.deviceBrowser.isConfigured {
                model.browseGarminMusicLibrary(force: true)
            } else {
                model.browseGarminMusicLibrary(force: !model.deviceBrowser.hasFreshListing)
            }
            var spins = 0
            while model.isBrowsingDevice || model.deviceBrowser.isRefreshing, spins < 40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                spins += 1
            }
        } else if let dest = model.activeDestination {
            model.refreshDeviceContents(at: dest)
        }
    }

    /// Deep scan: Transfer queue + ~/Music + Apple Music local files (deduped by path).
    func gatherMacCatalog(model: AppModel) async -> ([AudioTrack], GuidedCatalogStats) {
        var byPath: [String: AudioTrack] = [:]
        var stats = GuidedCatalogStats()
        let fast = model.librarySettings.fastImport
        let concurrency = model.librarySettings.importConcurrency

        if enabledScanSources.contains(.transferQueue) {
            analysisProgress = "Reading Transfer queue…"
            for track in model.tracks {
                byPath[track.url.standardizedFileURL.path] = track
            }
            stats.queueCount = model.tracks.count
        }

        if enabledScanSources.contains(.musicFolder) {
            analysisProgress = "Scanning ~/Music (this may take a minute)…"
            let musicRoot = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
            var urls = scanner.findAudioFiles(in: musicRoot)
            if urls.count > Self.musicFolderScanCap {
                urls = Array(urls.prefix(Self.musicFolderScanCap))
                analysisProgress = "Scanning first \(Self.musicFolderScanCap) files in ~/Music…"
            }
            // Skip Music Library package internals; keep Media.localized + loose files under Music.
            urls = urls.filter { !$0.path.contains(".musiclibrary/") }
            let scanned = await scanner.scanFiles(
                urls,
                fastImport: fast || urls.count > 800,
                maxConcurrency: concurrency
            )
            stats.musicFolderCount = scanned.count
            for track in scanned {
                let key = track.url.standardizedFileURL.path
                if byPath[key] == nil {
                    byPath[key] = track
                }
            }
        }

        if enabledScanSources.contains(.appleMusicLocal) {
            analysisProgress = "Loading Apple Music local tracks…"
            do {
                let snapshot = try appleMusic.loadSnapshot()
                var added = 0
                for libTrack in snapshot.tracksByID.values where libTrack.isImportable {
                    guard let url = libTrack.location else { continue }
                    let key = url.standardizedFileURL.path
                    if byPath[key] != nil { continue }
                    if let track = makeTrack(from: libTrack, url: url) {
                        byPath[key] = track
                        added += 1
                    }
                }
                stats.appleMusicCount = added
            } catch {
                analysisProgress = "Apple Music unavailable: \(error.localizedDescription)"
            }
        }

        stats.uniqueTracks = byPath.count
        return (Array(byPath.values), stats)
    }

    private func makeTrack(from lib: LibraryTrack, url: URL) -> AudioTrack? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let ext = (lib.fileExtension ?? url.pathExtension).lowercased()
        let compat = MusicCompatibilityEvaluator.evaluate(
            url: url,
            ext: ext,
            codecHint: nil,
            title: lib.title,
            artist: lib.artist,
            byteCount: size
        )
        return AudioTrack(
            url: url,
            fileName: url.lastPathComponent,
            fileExtension: ext,
            title: lib.title,
            artist: lib.artist,
            album: lib.album,
            durationSeconds: nil,
            byteCount: size,
            codecHint: nil,
            compatibility: compat,
            isSelected: compat.canCopy
        )
    }

    // MARK: - Plan build

    func buildPlan(
        mode: GuidedTransferMode,
        model: AppModel,
        macTracks: [AudioTrack],
        stats: GuidedCatalogStats
    ) -> GuidedTransferPlan {
        let watchName = model.connectedMTPDeviceName
            ?? model.connectedUSBDevices.first?.displayName
            ?? model.selectedDevice?.volumeName
            ?? "Garmin"
        let free = model.deviceBrowser.storageInfo?.availableCapacity
        let deviceAudio = model.deviceBrowser.files.filter { $0.type == .audio }
        var items: [GuidedPlanItem] = []

        var deviceKeys = Set<String>()
        for file in deviceAudio {
            for key in TrackMatching.deviceFingerprintKeys(for: file) {
                deviceKeys.insert(key)
            }
        }

        var macKeys = Set<String>()
        for track in macTracks {
            for key in TrackMatching.trackFingerprintKeys(for: track) {
                macKeys.insert(key)
            }
        }

        // Pair exact matches for already-both; collect unmatched for conflict detection.
        var unmatchedMac = macTracks
        var unmatchedDevice = deviceAudio
        var exactMacIDs = Set<UUID>()
        var exactDeviceIDs = Set<String>()

        for track in macTracks {
            if let file = deviceAudio.first(where: { TrackMatching.isIdentical(track: track, existing: $0) }) {
                exactMacIDs.insert(track.id)
                exactDeviceIDs.insert(file.id)
                if mode == .toWatch || mode == .bothWays || mode == .fromWatch {
                    items.append(GuidedPlanItem(
                        bucket: .alreadyBoth,
                        direction: .none,
                        displayName: track.displayName,
                        detail: "Mac: \(track.fileName) · Watch: \(file.path)",
                        byteCount: track.byteCount,
                        reason: "Exact or smart match on both sides.",
                        trackID: track.id,
                        deviceFileID: file.id,
                        isIncluded: false,
                        macLabel: track.displayName,
                        watchLabel: file.audioMetadata?.title ?? file.name,
                        matchKind: "Strong match"
                    ))
                }
            }
        }
        unmatchedMac = macTracks.filter { !exactMacIDs.contains($0.id) }
        unmatchedDevice = deviceAudio.filter { !exactDeviceIDs.contains($0.id) }

        // Conflicts: loose name/title match without strong identity (bidirectional / to-watch / from-watch).
        var conflictedMac = Set<UUID>()
        var conflictedDevice = Set<String>()

        if mode == .bothWays || mode == .toWatch || mode == .fromWatch {
            for track in unmatchedMac {
                guard track.compatibility.canCopy else { continue }
                if let (file, kind) = findLooseMatch(track: track, in: unmatchedDevice) {
                    conflictedMac.insert(track.id)
                    conflictedDevice.insert(file.id)
                    items.append(GuidedPlanItem(
                        bucket: .conflict,
                        direction: .bidirectional,
                        displayName: track.displayName,
                        detail: "Similar on both sides — choose what to do.",
                        byteCount: max(track.byteCount, file.size),
                        reason: kind,
                        trackID: track.id,
                        deviceFileID: file.id,
                        isIncluded: true,
                        macLabel: "\(track.displayName) (\(ByteCountFormatter.string(fromByteCount: track.byteCount, countStyle: .file)))",
                        watchLabel: "\((file.audioMetadata?.title ?? file.name)) (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))",
                        matchKind: kind,
                        resolution: .skipBoth
                    ))
                }
            }
        }

        // Mac-only / cannot transfer
        if mode == .toWatch || mode == .bothWays {
            for track in unmatchedMac where !conflictedMac.contains(track.id) {
                if !track.compatibility.canCopy {
                    items.append(GuidedPlanItem(
                        bucket: .cannotTransfer,
                        direction: .none,
                        displayName: track.displayName,
                        detail: track.fileName,
                        byteCount: track.byteCount,
                        reason: track.compatibility.summary,
                        trackID: track.id,
                        isIncluded: false
                    ))
                } else {
                    items.append(GuidedPlanItem(
                        bucket: .toWatch,
                        direction: .toWatch,
                        displayName: track.displayName,
                        detail: track.fileName,
                        byteCount: track.byteCount,
                        trackID: track.id,
                        isIncluded: true
                    ))
                }
            }
        }

        // Watch-only
        if mode == .fromWatch || mode == .bothWays {
            for file in unmatchedDevice where !conflictedDevice.contains(file.id) {
                let name = file.audioMetadata?.title ?? file.name
                items.append(GuidedPlanItem(
                    bucket: .fromWatch,
                    direction: .fromWatch,
                    displayName: name,
                    detail: file.path,
                    byteCount: file.size,
                    deviceFileID: file.id,
                    isIncluded: true
                ))
            }
        }

        if (mode == .toWatch || mode == .bothWays), macTracks.isEmpty {
            items.append(GuidedPlanItem(
                bucket: .skip,
                direction: .none,
                displayName: "No Mac music found",
                reason: "Enable scan sources (queue, Music folder, Apple Music) or add files on Transfer.",
                isIncluded: false
            ))
        }

        return GuidedTransferPlan(
            mode: mode,
            items: items,
            analyzedAt: Date(),
            watchDisplayName: watchName,
            freeBytesOnWatch: free,
            catalogStats: stats
        )
    }

    /// Loose match used for conflict UI (never auto-transfer).
    private func findLooseMatch(track: AudioTrack, in files: [DeviceFile]) -> (DeviceFile, String)? {
        for file in files {
            if TrackMatching.namesMatch(localFileName: track.fileName, remoteFileName: file.name),
               !TrackMatching.sizesMatch(local: track.byteCount, remote: file.size) {
                return (file, "Same filename, different size")
            }
            if TrackMatching.metadataTitlesMatch(localTitle: track.title, remoteTitle: file.audioMetadata?.title) {
                let artistSame = TrackMatching.artistsMatch(local: track.artist, remote: file.audioMetadata?.artist)
                if artistSame {
                    return (file, "Same title + artist, not a strong file match")
                }
                return (file, "Same title only — may be different recordings")
            }
        }
        return nil
    }

    func toggleInclude(itemID: UUID) {
        guard var plan else { return }
        guard let idx = plan.items.firstIndex(where: { $0.id == itemID }) else { return }
        guard plan.items[idx].bucket != .cannotTransfer, plan.items[idx].bucket != .alreadyBoth else { return }
        plan.items[idx].isIncluded.toggle()
        self.plan = plan
    }

    func setConflictResolution(itemID: UUID, resolution: GuidedConflictResolution) {
        guard var plan else { return }
        guard let idx = plan.items.firstIndex(where: { $0.id == itemID }) else { return }
        guard plan.items[idx].bucket == .conflict else { return }
        plan.items[idx].resolution = resolution
        plan.items[idx].isIncluded = resolution != .skipBoth
        self.plan = plan
    }

    func continueToConfirm() {
        guard let plan, !plan.toWatchItems.isEmpty || !plan.fromWatchItems.isEmpty else {
            errorMessage = "Nothing selected to transfer. Include items or resolve conflicts, then continue."
            return
        }
        if plan.willExceedStorage {
            errorMessage = "Selected “to watch” music may exceed free space. Deselect tracks or free space first."
            return
        }
        errorMessage = nil
        step = .confirmPlan
    }

    // MARK: - Execute

    func startTransfer(model: AppModel) {
        guard let plan, let mode else { return }
        guard !plan.toWatchItems.isEmpty || !plan.fromWatchItems.isEmpty else {
            errorMessage = "Nothing to transfer."
            return
        }
        if plan.willExceedStorage {
            errorMessage = "Not enough free space on the watch."
            step = .errorRecovery
            return
        }

        errorMessage = nil
        isTransferring = true
        transferStartedAt = Date()
        step = .transferProgress
        summary = nil

        transferTask = Task { @MainActor in
            var toCount = 0
            var fromCount = 0
            var failed: [String] = []
            var bytes: Int64 = 0
            var cancelled = false

            if !plan.toWatchItems.isEmpty {
                transferProgress = .phase(0.05, "Preparing send to watch…")
                let ids = Set(plan.toWatchItems.compactMap(\.trackID))
                // Merge catalog into queue so scanned tracks can send without prior queue load.
                mergeCatalogIntoQueue(model: model, selectedIDs: ids)
                await model.sync()
                if Task.isCancelled { cancelled = true }
                toCount = plan.toWatchItems.count
                bytes += plan.toWatchBytes
                if !model.lastFailedTrackIDs.isEmpty {
                    let failedTracks = model.tracks.filter { model.lastFailedTrackIDs.contains($0.id) }
                    failed.append(contentsOf: failedTracks.map(\.displayName))
                    toCount = max(0, toCount - failedTracks.count)
                    bytes -= failedTracks.reduce(0) { $0 + $1.byteCount }
                }
            }

            if !cancelled, !plan.fromWatchItems.isEmpty {
                transferProgress = .phase(0.55, "Importing from watch…")
                let dest = defaultImportFolder()
                importDestinationPath = dest.path
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

                let fileIDs = Set(plan.fromWatchItems.compactMap(\.deviceFileID))
                model.deviceBrowser.selectedFileIDs = fileIDs
                model.isManagingDeviceFiles = true
                let result = await model.deviceBrowser.copySelected(to: dest)
                model.isManagingDeviceFiles = false
                if let result {
                    fromCount = result.completedCount
                    bytes += plan.fromWatchItems.prefix(result.completedCount).reduce(0) { $0 + $1.byteCount }
                    failed.append(contentsOf: result.failedItems)
                    if result.message?.localizedCaseInsensitiveContains("cancel") == true {
                        cancelled = true
                    }
                } else {
                    failed.append("Watch import did not complete.")
                }
            }

            isTransferring = false
            transferProgress = .phase(1, "Finished")
            let elapsed = Date().timeIntervalSince(transferStartedAt ?? Date())
            let skipCount = plan.skippedItems.count
            summary = GuidedTransferSummary(
                mode: mode,
                watchName: plan.watchDisplayName,
                toWatchCount: toCount,
                fromWatchCount: fromCount,
                skippedCount: skipCount,
                failedCount: failed.count,
                bytesTransferred: max(0, bytes),
                duration: elapsed,
                wasCancelled: cancelled,
                failedNames: failed,
                message: cancelled
                    ? "Transfer cancelled. Completed items were kept."
                    : (failed.isEmpty ? "Transfer finished successfully." : "Transfer finished with some failures.")
            )
            step = .completeSummary

            let moved = toCount + fromCount
            model.presentNotice(
                failed.isEmpty && !cancelled ? .success : .warning,
                title: cancelled ? "Transfer cancelled" : "Music transfer complete",
                message: "\(moved) item(s) moved. \(skipCount) skipped.\(failed.isEmpty ? "" : " \(failed.count) failed.")",
                action: .showOnWatch,
                alsoLog: true
            )
        }
    }

    /// Ensures planned catalog tracks exist on the Transfer queue and are selected.
    private func mergeCatalogIntoQueue(model: AppModel, selectedIDs: Set<UUID>) {
        var byID = Dictionary(uniqueKeysWithValues: model.tracks.map { ($0.id, $0) })
        for track in macCatalog {
            if byID[track.id] == nil {
                byID[track.id] = track
            }
        }
        model.tracks = byID.values.map { track in
            var t = track
            t.isSelected = selectedIDs.contains(track.id) && track.compatibility.canCopy
            return t
        }
    }

    func cancelTransfer(model: AppModel) {
        model.cancelSync()
        model.cancelDeviceOperation()
        transferTask?.cancel()
        isTransferring = false
    }

    private func defaultImportFolder() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Garmin Imports", isDirectory: true)
    }
}
