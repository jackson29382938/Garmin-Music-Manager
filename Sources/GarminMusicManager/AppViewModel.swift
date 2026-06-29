import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var devices: [GarminDevice] = []
    @Published var destinationURL: URL?
    @Published var libraryURL: URL?
    @Published var tracks: [MusicTrack] = []
    @Published var filterText = ""
    @Published var logEntries: [LogEntry] = []
    @Published var destinationHealth: DestinationHealth = .unknown
    @Published var destinationFreeSpaceText: String?
    @Published var preflightMessages: [String] = []
    @Published var useExperimentalMTP = false
    @Published var mtpStatusText = ExperimentalMTPBackend.statusText
    @Published var selectedMetadataTrackID: UUID?
    @Published var metadataDraft = EditableMetadata()
    @Published var conversionPreset: ConversionPreset = .aac192

    let logFileURL = DebugLog.fileURL

    init() {
        DebugLog.prepareLogDirectory()
        log(.info, "App launched", detail: "Persistent log: \(logFileURL.path)")
        log(.info, "Tool status", detail: "ffmpeg: \(AudioConverter.isAvailable ? "found" : "missing")\nMTP: \(ExperimentalMTPBackend.statusText)")
    }

    var selectedReadyTrackCount: Int {
        tracks.filter { $0.isSelected && $0.status != .unsupported }.count
    }

    var selectedTrackCount: Int { tracks.filter(\.isSelected).count }

    var selectedBytes: Int64 {
        tracks
            .filter { $0.isSelected && $0.status != .unsupported }
            .compactMap { $0.fileSizeBytes.map(Int64.init) }
            .reduce(0, +)
    }

    var selectedBytesText: String {
        selectedBytes > 0 ? ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file) : "No selected size"
    }

    var canSync: Bool {
        useExperimentalMTP ? selectedReadyTrackCount > 0 : (destinationURL != nil && selectedReadyTrackCount > 0)
    }

    var formattedDebugLog: String {
        logEntries.map { $0.formatted }.joined(separator: "\n")
    }

    var filteredTracks: [MusicTrack] {
        let query = filterText.trimmed.lowercased()
        guard !query.isEmpty else { return tracks }
        return tracks.filter { $0.searchableText.contains(query) }
    }

    var selectedTrackForMetadata: MusicTrack? {
        guard let selectedMetadataTrackID else { return nil }
        return tracks.first(where: { $0.id == selectedMetadataTrackID })
    }

    func binding(for track: MusicTrack) -> Binding<MusicTrack>? {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        return Binding(
            get: { self.tracks[index] },
            set: { self.tracks[index] = $0 }
        )
    }

    func scanDevices() {
        devices = GarminVolumeScanner.scanMountedVolumes()
        mtpStatusText = ExperimentalMTPBackend.statusText
        log(.info, "Scanned devices", detail: "Mounted Garmin-like candidates: \(devices.count)\nMTP status: \(mtpStatusText)")
    }

    func detectMTPDevice() {
        mtpStatusText = ExperimentalMTPBackend.statusText
        do {
            let summary = try ExperimentalMTPBackend.detectDeviceSummary()
            log(.info, "MTP detect succeeded", detail: summary.prefix(6000).description)
            do {
                let files = try ExperimentalMTPBackend.listFilesSummary()
                log(.info, "MTP file listing succeeded", detail: files.prefix(6000).description)
            } catch {
                log(.warning, "MTP file listing failed", detail: String(describing: error))
            }
        } catch {
            log(.error, "MTP detect failed", detail: String(describing: error))
        }
    }

    func useDevice(_ device: GarminDevice) {
        destinationURL = device.suggestedMusicFolderURL
        useExperimentalMTP = false
        destinationHealth = .unknown
        destinationFreeSpaceText = nil
        preflightMessages.removeAll()
        log(.info, "Selected mounted destination", detail: device.suggestedMusicFolderURL.path)
        validateDestinationForUser()
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Garmin music destination folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            log(.info, "Destination folder picker cancelled")
            return
        }

        destinationURL = url
        useExperimentalMTP = false
        destinationHealth = .unknown
        destinationFreeSpaceText = nil
        preflightMessages.removeAll()
        log(.info, "Selected destination manually", detail: url.path)
        validateDestinationForUser()
    }

    func validateDestinationForUser() {
        guard let destinationURL else {
            destinationHealth = .invalid
            log(.error, "Destination validation failed", detail: "No destination selected.")
            return
        }

        do {
            let result = try DestinationValidator.validate(destinationURL)
            destinationHealth = result.warnings.isEmpty ? .valid : .warning
            destinationFreeSpaceText = result.availableCapacity.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            preflightMessages = result.messages
            log(result.warnings.isEmpty ? .info : .warning, "Destination validated", detail: result.messages.joined(separator: "\n"))
        } catch {
            destinationHealth = .invalid
            preflightMessages = [error.localizedDescription]
            log(.error, "Destination validation failed", detail: String(describing: error))
        }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder containing local music files"
        panel.prompt = "Scan Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            log(.info, "Music folder picker cancelled")
            return
        }

        libraryURL = url
        scanLibrary(at: url)
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose music files"
        panel.prompt = "Add Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = MusicInspector.scanExtensions

        guard panel.runModal() == .OK else {
            log(.info, "Add files picker cancelled")
            return
        }

        let newTracks = panel.urls.map { MusicInspector.inspect(url: $0) }
        mergeTracks(newTracks)
        log(.info, "Added files", detail: "Added \(newTracks.count) file(s).")
    }

    func scanLibrary(at url: URL) {
        let result = MusicInspector.findCandidateAudioFiles(in: url)
        let inspected = result.urls.map { MusicInspector.inspect(url: $0) }
        tracks = inspected.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        log(.info, "Scanned music library", detail: "Loaded \(tracks.count) candidate audio file(s) from \(url.path).")

        if !result.skippedPaths.isEmpty {
            log(.warning, "Some paths were skipped during scan", detail: result.skippedPaths.prefix(40).joined(separator: "\n"))
        }

        let unsupportedCount = tracks.filter { $0.status == .unsupported }.count
        let warningCount = tracks.filter { $0.status == .warning }.count
        if unsupportedCount > 0 || warningCount > 0 {
            log(.warning, "Compatibility warnings found", detail: "\(unsupportedCount) unsupported, \(warningCount) warning(s).")
        }
    }

    func clearTracks() {
        tracks.removeAll()
        preflightMessages.removeAll()
        selectedMetadataTrackID = nil
        log(.info, "Cleared loaded tracks")
    }

    func selectReadyTracks() {
        for index in tracks.indices {
            tracks[index].isSelected = tracks[index].status == .ready
        }
        log(.info, "Selected ready tracks", detail: "Selected \(selectedReadyTrackCount) ready track(s).")
    }

    func selectAllNonUnsupportedTracks() {
        for index in tracks.indices {
            tracks[index].isSelected = tracks[index].status != .unsupported
        }
        log(.info, "Selected all non-unsupported tracks", detail: "Selected \(selectedReadyTrackCount) track(s).")
    }

    func deselectAllTracks() {
        for index in tracks.indices { tracks[index].isSelected = false }
        log(.info, "Deselected all tracks")
    }

    func convertSelectedTracks() {
        let selectedIDs = tracks.filter(\.isSelected).map(\.id)
        guard !selectedIDs.isEmpty else {
            log(.warning, "Conversion skipped", detail: "No tracks selected.")
            return
        }

        guard AudioConverter.isAvailable else {
            log(.error, "Conversion unavailable", detail: "ffmpeg was not found. Install ffmpeg and relaunch the app.")
            return
        }

        var success = 0
        var failed = 0

        for id in selectedIDs {
            guard let index = tracks.firstIndex(where: { $0.id == id }) else { continue }
            do {
                let output = try AudioConverter.convert(track: tracks[index], preset: conversionPreset, metadata: tracks[index].metadata)
                tracks[index].workingURL = output
                tracks[index].generatedCopyReason = conversionPreset.rawValue
                tracks[index].issues.removeAll { $0.severity == .unsupported }
                tracks[index].isSelected = true
                success += 1
                log(.info, "Converted track", detail: "\(tracks[index].originalURL.path) -> \(output.path)")
            } catch {
                failed += 1
                log(.error, "Track conversion failed", detail: "\(tracks[index].originalURL.path)\n\(String(describing: error))")
            }
        }

        log(failed == 0 ? .info : .warning, "Conversion batch finished", detail: "Converted: \(success)\nFailed: \(failed)")
    }

    func beginMetadataRepair(for track: MusicTrack) {
        selectedMetadataTrackID = track.id
        metadataDraft = track.metadata
    }

    func applyMetadataRepair() {
        guard let id = selectedMetadataTrackID, let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        guard MetadataRepairer.isAvailable else {
            tracks[index].metadata = metadataDraft
            tracks[index].issues.removeAll { issue in
                issue.message.contains("Missing title") || issue.message.contains("Missing artist")
            }
            log(.warning, "Saved metadata in app only", detail: "ffmpeg was not found, so no repaired audio copy was written. The sync filename/playlist will use the edited values, but file tags were not rewritten.")
            selectedMetadataTrackID = nil
            return
        }

        do {
            let outputURL = try MetadataRepairer.repair(track: tracks[index], metadata: metadataDraft)
            tracks[index].metadata = metadataDraft
            tracks[index].workingURL = outputURL
            tracks[index].generatedCopyReason = "metadata repaired"
            tracks[index].issues.removeAll { issue in
                issue.message.contains("Missing title") || issue.message.contains("Missing artist")
            }
            selectedMetadataTrackID = nil
            log(.info, "Metadata repair created copy", detail: outputURL.path)
        } catch {
            log(.error, "Metadata repair failed", detail: String(describing: error))
        }
    }

    func cancelMetadataRepair() {
        selectedMetadataTrackID = nil
    }

    func previewSync() {
        do {
            let plan = try buildSyncPlan()
            preflightMessages = plan.summaryMessages
            destinationHealth = plan.warnings.isEmpty ? .valid : .warning
            log(plan.warnings.isEmpty ? .info : .warning, "Sync preview created", detail: plan.debugSummary)
        } catch {
            destinationHealth = .invalid
            preflightMessages = [error.localizedDescription]
            log(.error, "Sync preview failed", detail: String(describing: error))
        }
    }

    func syncSelectedTracks() {
        do {
            let plan = try buildSyncPlan()
            preflightMessages = plan.summaryMessages
            destinationHealth = plan.warnings.isEmpty ? .valid : .warning
            log(.info, "Starting sync", detail: plan.debugSummary)

            let result = try MusicSyncEngine.sync(plan: plan) { level, message, detail in
                self.log(level, message, detail: detail)
            }

            preflightMessages = result.summaryMessages
            destinationHealth = result.failed == 0 ? .valid : .warning
            log(result.failed == 0 ? .info : .warning, "Sync completed", detail: result.debugSummary)
        } catch {
            destinationHealth = .invalid
            preflightMessages = [error.localizedDescription]
            log(.error, "Sync failed", detail: String(describing: error))
        }
    }

    func copyDebugLogToClipboard() {
        let visibleLog = formattedDebugLog
        let persistentLog = DebugLog.readAll()
        let text = [visibleLog, persistentLog].filter { !$0.isEmpty }.joined(separator: "\n--- Persistent log ---\n")
        NSPasteboard.copyString(text.isEmpty ? "No debug log entries." : text)
        log(.info, "Copied debug log to clipboard", detail: "Visible entries: \(logEntries.count)")
    }

    func exportDebugLog() {
        let panel = NSSavePanel()
        panel.title = "Export Garmin Music Manager Debug Log"
        panel.nameFieldStringValue = "GarminMusicManager-debug-log.txt"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            log(.info, "Debug log export cancelled")
            return
        }

        do {
            let text = [formattedDebugLog, DebugLog.readAll()].filter { !$0.isEmpty }.joined(separator: "\n--- Persistent log ---\n")
            try text.write(to: url, atomically: true, encoding: .utf8)
            log(.info, "Exported debug log", detail: url.path)
        } catch {
            log(.error, "Failed to export debug log", detail: String(describing: error))
        }
    }

    func openLogFolder() {
        DebugLog.openInFinder()
        log(.info, "Opened log folder", detail: logFileURL.path)
    }

    func clearVisibleLog() {
        logEntries.removeAll()
        log(.info, "Cleared visible log", detail: "Persistent log file was not deleted: \(logFileURL.path)")
    }

    private func buildSyncPlan() throws -> SyncPlan {
        let selected = tracks.filter { $0.isSelected && $0.status != .unsupported }
        guard !selected.isEmpty else { throw AppError.noTracksSelected }

        if useExperimentalMTP {
            guard ExperimentalMTPBackend.isAvailable else { throw AppError.mtpUnavailable(ExperimentalMTPBackend.statusText) }
            let entries = selected.map { track in
                SyncPlan.Entry(
                    track: track,
                    destinationURL: URL(fileURLWithPath: FileNameSanitizer.safeFileName(for: track))
                )
            }
            let totalBytes = selected.compactMap { $0.fileSizeBytes.map(Int64.init) }.reduce(0, +)
            return SyncPlan(destinationRootURL: nil, syncFolderURL: nil, playlistURL: nil, entries: entries, totalBytes: totalBytes, availableCapacity: nil, warnings: ["MTP mode is experimental and depends on libmtp behavior for the connected watch."], useMTP: true)
        }

        guard let destinationURL else { throw AppError.noDestination }
        let destinationResult = try DestinationValidator.validate(destinationURL)
        let syncFolder = destinationURL.appendingPathComponent("GarminMusicManager", isDirectory: true)
        let totalBytes = selected.compactMap { $0.fileSizeBytes.map(Int64.init) }.reduce(0, +)

        var warnings = destinationResult.warnings
        if let available = destinationResult.availableCapacity, totalBytes > available {
            warnings.append("Selected tracks are larger than available destination space.")
        }

        let entries = selected.map { track in
            SyncPlan.Entry(
                track: track,
                destinationURL: FileNameSanitizer.uniqueURL(in: syncFolder, preferredFileName: FileNameSanitizer.safeFileName(for: track))
            )
        }

        return SyncPlan(
            destinationRootURL: destinationURL,
            syncFolderURL: syncFolder,
            playlistURL: syncFolder.appendingPathComponent("GarminMusicManager.m3u8"),
            entries: entries,
            totalBytes: totalBytes,
            availableCapacity: destinationResult.availableCapacity,
            warnings: warnings,
            useMTP: false
        )
    }

    private func mergeTracks(_ newTracks: [MusicTrack]) {
        var knownURLs = Set(tracks.map { $0.originalURL.resolvingSymlinksInPath() })
        for track in newTracks {
            let normalizedURL = track.originalURL.resolvingSymlinksInPath()
            guard !knownURLs.contains(normalizedURL) else {
                log(.warning, "Skipped duplicate file", detail: track.originalURL.path)
                continue
            }
            tracks.append(track)
            knownURLs.insert(normalizedURL)
        }
        tracks.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private func log(_ level: LogLevel, _ message: String, detail: String? = nil) {
        let entry = LogEntry(level: level, message: message, detail: detail)
        logEntries.append(entry)
        if logEntries.count > 500 { logEntries.removeFirst(logEntries.count - 500) }
        DebugLog.append(entry)
    }
}
