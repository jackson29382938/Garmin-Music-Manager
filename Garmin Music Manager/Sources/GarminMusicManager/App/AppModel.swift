import AppKit
import Combine
import GarminMusicCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [GarminDevice] = []
    @Published var connectedUSBDevices: [GarminUSBDevice] = []
    @Published var mtpDependencyStatus = MTPDependencyStatus(homebrewURL: nil, libmtpLibraryURL: nil, libmtpHeaderURL: nil)
    @Published var isInstallingMTPDependencies = false
    @Published var selectedDevice: GarminDevice?
    @Published var tracks: [AudioTrack] = []
    @Published var deviceFiles: [DeviceAudioFile] = []
    @Published var storageInfo: StorageInfo?
    @Published var transferLog: [String] = []
    @Published var isSyncing = false
    @Published var isScanning = false
    @Published var isManagingDeviceFiles = false
    @Published var syncProgress: Double = 0
    @Published var playlistName: String
    @Published var destinationMode: GarminDestinationMode
    @Published var destinationOverride: URL?
    @Published var destinationWarning: String?
    @Published var syncSettings: SyncSettings
    @Published var searchText = ""
    @Published var showSyncPreview = false
    @Published var syncPreview: SyncPreview?
    @Published var selectedDeviceFileIDs: Set<String> = []
    @Published var showDeleteConfirmation = false
    @Published var showResetConfirmation = false
    @Published var showMoveWithinGarminSheet = false
    @Published var moveTargetPath = ""
    @Published var showMTPMoveDeleteConfirmation = false
    @Published var advancedStorageExplorerEnabled: Bool {
        didSet {
            settingsStore.advancedStorageExplorerEnabled = advancedStorageExplorerEnabled
            if !advancedStorageExplorerEnabled {
                deviceBrowser.setBrowseMode(.musicOnly, advancedEnabled: false)
                settingsStore.lastDeviceBrowseMode = .musicOnly
                Task { await deviceBrowser.refresh(force: false) }
            }
        }
    }
    @Published var destructiveConfirmationMode: DestructiveConfirmationMode {
        didSet {
            settingsStore.destructiveConfirmationMode = destructiveConfirmationMode
        }
    }

    @Published var showAppleMusicBrowser = false
    @Published var musicLibrary: MusicLibrarySnapshot = .empty
    @Published var musicLibraryStatus: MusicLibraryStatus = .idle

    @Published var isBrowsingDevice = false
    @Published var isMTPLibraryLoaded = false
    @Published var devicePlaylists: [DevicePlaylist] = []
    @Published var connectedMTPDeviceName: String?
    @Published var deviceBrowseMessage: String?
    @Published var deviceBrowser = DeviceBrowserStore()

    private var garminFileIDByName: [String: String] = [:]
    private var browseTask: Task<Void, Never>?
    private var deviceFileTask: Task<Void, Never>?
    private var pendingMTPMoveOriginals: [DeviceFile] = []
    private let detector = DeviceDetector()
    private let scanner = MusicScanner()
    private let syncCoordinator = SyncCoordinator()
    private let deviceLibraryCoordinator = DeviceLibraryCoordinator()
    private let deviceOperationsCoordinator = DeviceOperationsCoordinator()
    private let libraryImportCoordinator = LibraryImportCoordinator()
    private let mtpDependencyManager = MTPDependencyManager()
    private let contentService = DeviceContentService()
    private let appleMusic = AppleMusicLibrary()
    private let transferLogStore = TransferLogStore()
    private let settingsStore: SettingsStore
    private var syncTask: Task<Void, Never>?
    private var deviceBrowserCancellable: AnyCancellable?
    private var transferLogCancellable: AnyCancellable?

    init(settingsStore: SettingsStore = SettingsStore(), autoRefresh: Bool = true) {
        self.settingsStore = settingsStore
        self.playlistName = settingsStore.playlistName
        self.syncSettings = settingsStore.syncSettings
        self.destinationMode = settingsStore.destinationMode
        let storedDestination = settingsStore.destinationMode == .customFolder ? settingsStore.lastDestinationURL : nil
        self.destinationOverride = storedDestination
        self.destinationWarning = storedDestination.flatMap { Self.customDestinationWarning(for: $0) }
        self.advancedStorageExplorerEnabled = settingsStore.advancedStorageExplorerEnabled
        self.destructiveConfirmationMode = settingsStore.destructiveConfirmationMode
        self.deviceBrowser.browseMode = settingsStore.advancedStorageExplorerEnabled
            ? settingsStore.lastDeviceBrowseMode
            : .musicOnly
        self.deviceBrowserCancellable = deviceBrowser.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.transferLogCancellable = transferLogStore.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.transferLog = self.transferLogStore.lines
            self.objectWillChange.send()
        }
        self.mtpDependencyStatus = mtpDependencyManager.dependencyStatus()
        if autoRefresh {
            if let destination = destinationOverride {
                refreshDeviceContents(at: destination)
            }
            Task { refreshDevices() }
        }
    }

    var syncableTracks: [AudioTrack] {
        tracks.filter { $0.compatibility.canCopy && $0.isSelected }
    }

    var blockedTracks: [AudioTrack] {
        tracks.filter { !$0.compatibility.canCopy }
    }

    var filteredTracks: [AudioTrack] {
        guard !searchText.isEmpty else { return tracks }
        let query = searchText.lowercased()
        return tracks.filter {
            $0.displayName.lowercased().contains(query)
                || $0.fileName.lowercased().contains(query)
                || ($0.artist?.lowercased().contains(query) ?? false)
                || ($0.album?.lowercased().contains(query) ?? false)
        }
    }

    var activeDestination: URL? {
        switch destinationMode {
        case .autoDetected:
            return selectedDevice?.bestMusicDirectory
        case .customFolder:
            return destinationOverride
        }
    }

    var hasMTPDestination: Bool {
        activeDestination == nil && !connectedUSBDevices.isEmpty
    }

    var canAttemptMTP: Bool {
        hasMTPDestination && mtpDependencyStatus.isReady
    }

    var destinationDescription: String {
        if destinationMode == .customFolder, let destinationOverride {
            return destinationOverride.path
        }
        if destinationMode == .customFolder {
            return "Choose a custom Garmin folder"
        }
        if let activeDestination {
            return activeDestination.path
        }
        if hasMTPDestination {
            let deviceName = connectedMTPDeviceName ?? connectedUSBDevices.first?.displayName ?? "Garmin watch"
            if mtpDependencyStatus.isReady {
                return "Garmin MTP: \(deviceName) / Music"
            }
            return "Garmin MTP: \(deviceName) (install MTP support to sync)"
        }
        return "No destination selected"
    }

    var destinationIsReady: Bool {
        activeDestination != nil || canAttemptMTP
    }

    var canSync: Bool {
        !isSyncing
            && !isManagingDeviceFiles
            && !isBrowsingDevice
            && !syncableTracks.isEmpty
            && (activeDestination != nil || canAttemptMTP)
    }

    var canUploadSelectedTracksToDevice: Bool {
        !isSyncing
            && !isManagingDeviceFiles
            && !syncableTracks.isEmpty
            && (deviceBrowser.isConfigured || activeDestination != nil || canAttemptMTP)
            && deviceBrowser.browseMode == .musicOnly
    }

    var macLibraryLocationDescription: String {
        if tracks.isEmpty {
            return "No Mac music loaded"
        }
        let folders = Set(tracks.map { $0.url.deletingLastPathComponent().path })
        if folders.count == 1, let folder = folders.first {
            return folder
        }
        return "\(folders.count) Mac folders"
    }

    var garminLibraryLocationDescription: String {
        if let name = deviceBrowser.deviceName, deviceBrowser.backendKind == .mtp {
            return "\(name) / Music"
        }
        return destinationDescription
    }

    var transferTargetDescription: String {
        if let activeDestination {
            return activeDestination.path
        }
        if hasMTPDestination {
            return mtpDependencyStatus.isReady ? "Garmin MTP device / Music / \(playlistName)" : "Install MTP support to sync directly to the Garmin"
        }
        return "Choose a destination folder first"
    }

    var selectedTracksByteCount: Int64 {
        syncableTracks.reduce(0) { $0 + $1.byteCount }
    }

    var duplicateTrackCount: Int {
        tracks.filter(\.isDuplicateOnDevice).count
    }

    var syncSummaryText: String {
        var parts = ["\(syncableTracks.count) selected"]
        if syncableTracks.count > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: selectedTracksByteCount, countStyle: .file))
        }
        if duplicateTrackCount > 0 {
            parts.append("\(duplicateTrackCount) on device")
        }
        if hasMTPDestination && mtpDependencyStatus.isReady {
            parts.append("MTP")
        } else if activeDestination != nil {
            parts.append("Folder")
        }
        return parts.joined(separator: " · ")
    }

    var uploadDisabledReason: String? {
        if isSyncing || isManagingDeviceFiles { return "A transfer is already in progress." }
        if syncableTracks.isEmpty { return "Select compatible tracks in the Mac Library first." }
        if !deviceBrowser.isConfigured && activeDestination == nil && !canAttemptMTP {
            return "Connect a Garmin or choose a destination folder."
        }
        if deviceBrowser.browseMode != .musicOnly {
            return "Switch the Garmin browser back to Music."
        }
        return nil
    }

    var workflowSteps: [WorkflowStep] {
        let connected = destinationIsReady || !connectedUSBDevices.isEmpty || !devices.isEmpty
        let imported = !tracks.isEmpty
        let selected = !syncableTracks.isEmpty
        let syncing = isSyncing

        return [
            WorkflowStep(
                id: 1,
                title: "Connect",
                systemImage: "cable.connector",
                hint: "Connect your Garmin via USB and click Refresh in the sidebar.",
                isComplete: connected,
                isActive: !connected
            ),
            WorkflowStep(
                id: 2,
                title: "Import",
                systemImage: "square.and.arrow.down",
                hint: "Add music from your Mac using Add Files, Add Folder, or drag-and-drop.",
                isComplete: imported,
                isActive: connected && !imported
            ),
            WorkflowStep(
                id: 3,
                title: "Select",
                systemImage: "checkmark.circle",
                hint: "Check the tracks you want on your watch. Use Select Ready for compatible files.",
                isComplete: selected,
                isActive: imported && !selected
            ),
            WorkflowStep(
                id: 4,
                title: "Sync",
                systemImage: "arrow.down.circle",
                hint: "Name your playlist and click Sync Playlist to Garmin.",
                isComplete: false,
                isActive: selected,
                isInProgress: syncing
            )
        ]
    }

    var selectedDeviceFiles: [DeviceFile] {
        deviceBrowser.selectedFiles
    }

    var canMoveSelectedDeviceFiles: Bool {
        deviceBrowser.isConfigured
            && selectedDeviceFiles.contains { $0.type != .folder }
            && !isManagingDeviceFiles
    }

    var suggestedGarminMoveTargetPaths: [String] {
        var paths = [defaultMoveTargetPath()]
        let parentFolders = Set(deviceBrowser.files.map { file in
            (file.path as NSString).deletingLastPathComponent
        })

        for folder in parentFolders where !folder.isEmpty && folder != "." && folder != "/" {
            paths.append(normalizedMoveTargetPath(folder))
        }

        var seen: Set<String> = []
        return paths.filter { path in
            let key = path.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    var exceedsAvailableStorage: Bool {
        guard let available = deviceBrowser.storageInfo?.availableCapacity else { return false }
        return selectedTracksByteCount > available
    }

    func refreshDevices() {
        mtpDependencyStatus = mtpDependencyManager.dependencyStatus()
        appendLog("Refreshing Garmin devices…")

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([GarminDevice], [GarminUSBDevice]) in
                let detector = DeviceDetector()
                let devices = detector.findGarminDevices()
                let usbDevices = detector.findConnectedGarminUSBDevices()
                return (devices, usbDevices)
            }.value

            devices = result.0
            connectedUSBDevices = result.1
            if connectedUSBDevices.isEmpty {
                connectedMTPDeviceName = nil
                isMTPLibraryLoaded = false
                if activeDestination == nil {
                    deviceBrowser.clear(message: "Connect a Garmin over USB, then refresh to browse files on the watch.")
                    syncLegacyDeviceSnapshot()
                    deviceBrowseMessage = "Connect a Garmin over USB, then refresh to browse files on the watch."
                }
            }
            if selectedDevice == nil || !devices.contains(where: { $0.id == selectedDevice?.id }) {
                selectedDevice = devices.first
            }
            if destinationMode == .autoDetected, let device = selectedDevice, let musicDir = device.bestMusicDirectory {
                refreshDeviceContents(at: musicDir)
            }
            if devices.isEmpty, !connectedUSBDevices.isEmpty {
                let names = connectedUSBDevices.map(\.displayName).joined(separator: ", ")
                appendLog("Garmin MTP device detected: \(names).")
                configureMTPBrowser()
                if mtpDependencyStatus.isReady {
                    browseGarminMusicLibrary()
                } else {
                    deviceBrowseMessage = mtpDependencyStatus.message
                    deviceBrowser.statusMessage = mtpDependencyStatus.message
                }
            } else if devices.isEmpty {
                appendLog("Refreshed devices: no Garmin volume found and no Garmin USB/MTP device visible.")
            } else {
                appendLog("Refreshed devices: found \(devices.count) mounted Garmin candidate(s).")
            }
        }
    }

    func selectDevice(_ device: GarminDevice) {
        selectedDevice = device
        destinationMode = .autoDetected
        destinationOverride = nil
        destinationWarning = nil
        settingsStore.destinationMode = .autoDetected
        settingsStore.saveDestination(nil)
        if let musicDir = device.bestMusicDirectory {
            configureMountedBrowser(destination: musicDir, displayName: device.volumeName)
            refreshDeviceContents(at: musicDir)
            appendLog("Selected device: \(device.volumeName)")
        }
    }

    func chooseMusicFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose music files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MusicScanner.supportedPickerTypes

        if panel.runModal() == .OK {
            Task { await addFiles(panel.urls) }
        }
    }

    func chooseMusicFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder containing music"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            let urls = scanner.findAudioFiles(in: url)
            Task { await addFiles(urls) }
        }
    }

    func useAutoDetectedDestination() {
        destinationMode = .autoDetected
        destinationOverride = nil
        destinationWarning = nil
        settingsStore.destinationMode = .autoDetected
        settingsStore.saveDestination(nil)

        if let selectedDevice, let musicDir = selectedDevice.bestMusicDirectory {
            refreshDeviceContents(at: musicDir)
            appendLog("Using auto-detected Garmin Music folder.")
        } else {
            refreshDevices()
        }
    }

    func chooseCustomGarminFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Garmin destination folder"
        panel.message = "Select the Garmin Music folder, a Garmin subfolder, or a local test folder."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            setCustomGarminFolder(url)
        }
    }

    func chooseDestinationFolder() {
        chooseCustomGarminFolder()
    }

    func setCustomGarminFolder(_ url: URL) {
        destinationMode = .customFolder
        destinationOverride = url
        destinationWarning = Self.customDestinationWarning(for: url)
        settingsStore.destinationMode = .customFolder
        settingsStore.saveDestination(url)
        configureMountedBrowser(destination: url, displayName: url.lastPathComponent)
        refreshDeviceContents(at: url)
        appendLog("Custom Garmin destination set: \(url.path)")
        if let destinationWarning {
            appendLog(destinationWarning)
        }
    }

    private static func customDestinationWarning(for url: URL) -> String? {
        let lowerPath = url.standardizedFileURL.path.lowercased()
        let homeMusicPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .standardizedFileURL
            .path
            .lowercased()
        let looksLikeMacMusic = lowerPath == homeMusicPath
            || lowerPath.contains("/music/music/")
            || lowerPath.contains("/music/media.localized/")
            || lowerPath.contains("music library.musiclibrary")
            || lowerPath.contains("/itunes/")

        guard looksLikeMacMusic else { return nil }
        return "This looks like your Mac Music library. The Garmin destination should normally be the watch's Music folder or a test folder."
    }

    func addFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }

        let scanned = await scanner.scanFiles(urls)
        mergeTracks(scanned)
        updateDuplicateFlags()
        appendLog("Added \(scanned.count) file(s). \(syncableTracks.count) selected and ready.")
    }

    func handleDroppedURLs(_ urls: [URL]) {
        let fileURLs = libraryImportCoordinator.expandDroppedURLs(urls)
        Task { await addFiles(fileURLs) }
    }

    func removeTracks(at offsets: IndexSet) {
        let filtered = filteredTracks
        let idsToRemove = offsets.map { filtered[$0].id }
        tracks.removeAll { idsToRemove.contains($0.id) }
    }

    func clearTracks() {
        tracks.removeAll()
        appendLog("Cleared all tracks.")
    }

    func selectAllReady() {
        for index in tracks.indices {
            tracks[index].isSelected = tracks[index].compatibility.canCopy
        }
    }

    func deselectAll() {
        for index in tracks.indices {
            tracks[index].isSelected = false
        }
    }

    func refreshDeviceContents(at destination: URL? = nil) {
        guard let destination = destination ?? activeDestination else {
            if canAttemptMTP {
                browseGarminMusicLibrary()
                return
            }
            deviceBrowser.clear(message: "Connect a Garmin over USB or choose a destination folder to browse existing audio files.")
            syncLegacyDeviceSnapshot()
            deviceBrowseMessage = "Connect a Garmin over USB or choose a destination folder to browse existing audio files."
            return
        }
        configureMountedBrowser(destination: destination, displayName: selectedDevice?.volumeName ?? destination.lastPathComponent)
        Task {
            await deviceBrowser.refresh(force: true)
            syncLegacyDeviceSnapshot()
            deviceBrowseMessage = deviceBrowser.statusMessage
            updateDuplicateFlags()
        }
    }

    func updateDuplicateFlags() {
        tracks = deviceLibraryCoordinator.updateDuplicateFlags(
            tracks: tracks,
            deviceBrowser: deviceBrowser,
            activeDestination: activeDestination,
            isMTPLibraryMode: isMTPLibraryMode,
            playlistName: playlistName,
            syncSettings: syncSettings,
            contentService: contentService
        )
    }

    func prepareSyncPreview() {
        guard !syncableTracks.isEmpty else {
            appendLog("Nothing to sync. Add compatible selected files first.")
            return
        }
        guard let destination = activeDestination else {
            guard mtpDependencyStatus.isReady else {
                appendLog(mtpDependencyStatus.message)
                return
            }
            syncPreview = syncCoordinator.buildMTPPreview(
                tracks: syncableTracks,
                playlistName: playlistName,
                settings: syncSettings,
                deviceFiles: deviceBrowser.files
            )
            showSyncPreview = true
            return
        }

        do {
            syncPreview = try syncCoordinator.buildMountedPreview(
                tracks: syncableTracks,
                playlistName: playlistName,
                destination: destination,
                settings: syncSettings
            )
            showSyncPreview = true
        } catch {
            appendLog("Preview failed: \(error.localizedDescription)")
        }
    }

    func confirmSync() {
        showSyncPreview = false
        Task { await sync() }
    }

    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
        // Mid-file abort: cooperative cancel inside the helper progress callback.
        Task { await MTPHelperClient.cancelInFlightHelper() }
        appendLog("Sync cancelled.")
    }

    /// Cancels the in-flight device browse or file operation (refresh, upload,
    /// copy, delete, move). Over MTP this asks the helper to abort the current
    /// libmtp transfer (SIGUSR1), escalating to process kill if needed.
    func cancelDeviceOperation() {
        browseTask?.cancel()
        browseTask = nil
        deviceFileTask?.cancel()
        deviceFileTask = nil
        Task { await MTPHelperClient.cancelInFlightHelper() }
        appendLog("Device operation cancelled.")
    }

    func sync() async {
        guard !syncableTracks.isEmpty else {
            appendLog("Nothing to sync.")
            return
        }
        guard let destination = activeDestination else {
            await syncToMTP()
            return
        }

        syncTask?.cancel()
        isSyncing = true
        syncProgress = 0
        settingsStore.playlistName = playlistName
        settingsStore.syncSettings = syncSettings
        settingsStore.saveDestination(destination)
        appendLog("Starting sync to \(destination.path)")

        syncTask = Task {
            defer {
                isSyncing = false
                syncProgress = 1
                syncTask = nil
            }
            do {
                let result = try await syncCoordinator.syncMounted(
                    tracks: syncableTracks,
                    playlistName: playlistName,
                    destination: destination,
                    settings: syncSettings
                ) { [weak self] progress, message in
                    Task { @MainActor in
                        self?.syncProgress = progress
                        if let message { self?.appendLog(message) }
                    }
                }
                appendLog("Sync complete: copied \(result.copiedCount), skipped \(result.skippedCount), replaced \(result.replacedCount).")
                if syncSettings.writePlaylist {
                    appendLog("Playlist: \(result.playlistURL.lastPathComponent)")
                }
                refreshDeviceContents(at: destination)
            } catch is CancellationError {
                appendLog("Sync cancelled.")
            } catch {
                appendLog("Sync failed: \(error.localizedDescription)")
            }
        }
        await syncTask?.value
    }

    private func syncToMTP() async {
        guard mtpDependencyStatus.isReady else {
            appendLog(mtpDependencyStatus.message)
            return
        }

        syncTask?.cancel()
        isSyncing = true
        syncProgress = 0
        settingsStore.playlistName = playlistName
        settingsStore.syncSettings = syncSettings
        appendLog("Starting MTP sync to Garmin watch")

        syncTask = Task {
            defer {
                isSyncing = false
                syncProgress = 1
                syncTask = nil
            }
            do {
                try Task.checkCancellation()
                configureMTPBrowser()
                syncProgress = 0.05
                appendLog("Refreshing Garmin library before sync…")
                await deviceBrowser.refresh(force: true)
                try Task.checkCancellation()
                syncLegacyDeviceSnapshot()

                let preparedTracks = syncCoordinator.preparedTracks(syncableTracks, settings: syncSettings)
                let plan = MTPSyncPlanner.buildPlan(
                    tracks: preparedTracks,
                    playlistName: playlistName,
                    settings: syncSettings,
                    deviceFiles: deviceBrowser.files
                )

                if plan.transferCount == 0 {
                    appendLog("MTP sync complete: all \(plan.skippedCount) selected track(s) already on the Garmin.")
                    syncProgress = 1
                    browseGarminMusicLibrary()
                    return
                }

                try Task.checkCancellation()
                let result = await syncCoordinator.executeMTPPlan(plan, deviceBrowser: deviceBrowser) { [weak self] progress, message in
                    Task { @MainActor in
                        self?.syncProgress = progress
                        if let message { self?.appendLog(message) }
                    }
                }

                if result.failedCount > 0 {
                    appendLog("MTP sync partially complete: sent \(result.uploadedCount), skipped \(result.skippedCount), replaced \(result.replacedCount), \(result.failedCount) failed.")
                } else {
                    appendLog("MTP sync complete: sent \(result.uploadedCount), skipped \(result.skippedCount), replaced \(result.replacedCount).")
                }
                browseGarminMusicLibrary()
            } catch is CancellationError {
                appendLog("MTP sync cancelled.")
            } catch {
                appendLog("MTP sync failed: \(error.localizedDescription)")
            }
        }
        await syncTask?.value
    }

    func installMTPDependencies() {
        guard !isInstallingMTPDependencies else { return }
        isInstallingMTPDependencies = true
        appendLog("Installing portable MTP support (Homebrew/libmtp if needed)…")
        Task {
            defer { isInstallingMTPDependencies = false }
            do {
                try await mtpDependencyManager.installDependencies { [weak self] message in
                    Task { @MainActor in
                        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self?.appendLog(message)
                        }
                    }
                }
                mtpDependencyStatus = mtpDependencyManager.dependencyStatus()
                appendLog(mtpDependencyStatus.message)
                refreshDevices()
            } catch {
                appendLog("MTP dependency install failed: \(error.localizedDescription)")
            }
        }
    }

    func deleteSelectedDeviceFiles() {
        let files = selectedDeviceFiles
        guard !files.isEmpty else { return }

        isManagingDeviceFiles = true
        deviceFileTask = Task {
            defer { isManagingDeviceFiles = false }
            let result = await deviceBrowser.deleteSelected()
            if let result {
                appendLog(result.message ?? "Deleted \(result.completedCount) file(s).")
            } else if let error = deviceBrowser.lastError {
                appendLog("Delete failed: \(error)")
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
        }
    }

    func requestDeleteSelectedDeviceFiles() {
        let files = selectedDeviceFiles
        guard !files.isEmpty else { return }
        if shouldConfirmDelete(files: files) {
            showDeleteConfirmation = true
        } else {
            deleteSelectedDeviceFiles()
        }
    }

    func copySelectedDeviceFilesToMac() {
        let files = selectedDeviceFiles
        guard !files.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose where to copy Garmin files"
        panel.message = "Select a folder on this Mac."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isManagingDeviceFiles = true
        deviceFileTask = Task {
            defer { isManagingDeviceFiles = false }
            let result = await deviceBrowser.copySelected(to: destination)
            if let result {
                appendLog(result.message ?? "Copied \(result.completedCount) file(s) to \(destination.path).")
            } else if let error = deviceBrowser.lastError {
                appendLog("Copy failed: \(error)")
            }
        }
    }

    func startMoveSelectedWithinGarmin() {
        let files = selectedDeviceFiles
        guard !files.isEmpty else { return }
        moveTargetPath = defaultMoveTargetPath()
        showMoveWithinGarminSheet = true
    }

    func moveSelectedDeviceFiles() {
        startMoveSelectedWithinGarmin()
    }

    func moveSelectedWithinGarmin(to path: String) {
        let files = selectedDeviceFiles.filter { $0.type != .folder }
        guard !files.isEmpty else { return }

        let target = GarminFolderTarget(normalizedMoveTargetPath(path), defaultingTo: defaultMoveTargetPath())
        showMoveWithinGarminSheet = false
        moveTargetPath = target.storagePath

        isManagingDeviceFiles = true
        deviceFileTask = Task {
            defer { isManagingDeviceFiles = false }
            let result: DeviceFileOperationResult?
            if deviceBrowser.backendKind == .mtp {
                result = await deviceBrowser.copySelectedWithinMTP(to: target)
                if let result, result.completedCount > 0 {
                    let failedNames = Set(result.failedItems)
                    pendingMTPMoveOriginals = files.filter { !failedNames.contains($0.name) }
                    showMTPMoveDeleteConfirmation = !pendingMTPMoveOriginals.isEmpty
                }
            } else if let activeDestination {
                result = await deviceBrowser.moveSelected(to: target.destinationURL(relativeTo: activeDestination))
            } else {
                appendLog("Choose or connect a Garmin destination before moving files.")
                result = nil
            }

            if let result {
                appendLog(result.message ?? "Moved \(result.completedCount) file(s) within Garmin.")
            } else if let error = deviceBrowser.lastError {
                appendLog("Move failed: \(error)")
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
        }
    }

    func confirmDeleteOriginalsAfterMTPMove() {
        let originals = pendingMTPMoveOriginals
        pendingMTPMoveOriginals = []
        showMTPMoveDeleteConfirmation = false
        guard !originals.isEmpty else { return }

        isManagingDeviceFiles = true
        deviceFileTask = Task {
            defer { isManagingDeviceFiles = false }
            let result = await deviceBrowser.delete(originals)
            if let result {
                appendLog(result.message ?? "Deleted \(result.completedCount) original file(s) after MTP move.")
            } else if let error = deviceBrowser.lastError {
                appendLog("Could not delete original files after MTP move: \(error)")
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
        }
    }

    func cancelDeleteOriginalsAfterMTPMove() {
        pendingMTPMoveOriginals = []
        showMTPMoveDeleteConfirmation = false
        appendLog("Kept original files after copying within Garmin.")
    }

    func defaultMoveTargetPath() -> String {
        deviceOperationsCoordinator.defaultMoveTargetPath(playlistName: playlistName)
    }

    func normalizedMoveTargetPath(_ path: String) -> String {
        deviceOperationsCoordinator.normalizedMoveTargetPath(path, playlistName: playlistName)
    }

    var isMTPLibraryMode: Bool {
        deviceBrowser.backendKind == .mtp || activeDestination == nil && (
            hasMTPDestination
                || isBrowsingDevice
        )
    }

    /// Reads the music already on the Garmin watch over MTP and shows it in the
    /// "On Device" panel. macOS will not mount the watch as a folder, so this is
    /// the only way to surface the existing library.
    func browseGarminMusicLibrary() {
        guard !isBrowsingDevice, !isManagingDeviceFiles else { return }
        guard hasMTPDestination else {
            deviceBrowseMessage = "No Garmin MTP device is connected. Connect the watch over USB and refresh."
            deviceBrowser.statusMessage = deviceBrowseMessage
            appendLog(deviceBrowseMessage ?? "No Garmin MTP device is connected.")
            return
        }
        guard mtpDependencyStatus.isReady else {
            deviceBrowseMessage = mtpDependencyStatus.message
            deviceBrowser.statusMessage = mtpDependencyStatus.message
            appendLog(mtpDependencyStatus.message)
            return
        }

        browseTask?.cancel()
        configureMTPBrowser()
        isBrowsingDevice = true
        deviceBrowseMessage = nil
        appendLog("Loading Garmin music library over MTP…")
        browseTask = Task {
            defer {
                isBrowsingDevice = false
                browseTask = nil
            }
            await deviceBrowser.refresh(force: true)
            guard !Task.isCancelled else { return }
            syncLegacyDeviceSnapshot()
            deviceBrowseMessage = deviceBrowser.statusMessage
            isMTPLibraryLoaded = !deviceBrowser.files.isEmpty || !deviceBrowser.collections.isEmpty
            if let deviceName = deviceBrowser.deviceName {
                connectedMTPDeviceName = deviceName
            }
            updateDuplicateFlags()
            let playlistCount = deviceBrowser.collections.filter { $0.kind == .playlist }.count
            let playlistSummary = playlistCount == 0 ? "no playlists" : "\(playlistCount) playlist(s)"
            appendLog("Garmin library: \(deviceBrowser.files.filter { $0.type == .audio }.count) audio file(s), \(playlistSummary).")
            if let error = deviceBrowser.lastError {
                appendLog("Could not read Garmin library: \(error)")
            } else if let diagnosticMessage = deviceBrowser.statusMessage {
                appendLog(diagnosticMessage)
            }
        }
    }

    func switchDeviceBrowseMode(to mode: DeviceBrowseMode) {
        deviceBrowser.setBrowseMode(mode, advancedEnabled: advancedStorageExplorerEnabled)
        settingsStore.lastDeviceBrowseMode = deviceBrowser.browseMode
        browseTask = Task {
            await deviceBrowser.refresh(force: false)
            guard !Task.isCancelled else { return }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
        }
    }

    func chooseFilesToUploadToDevice() {
        guard deviceBrowser.isConfigured else {
            appendLog("Choose or connect a Garmin destination first.")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose music files to add to Garmin"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MusicScanner.supportedPickerTypes

        guard panel.runModal() == .OK else { return }
        uploadFilesToDevice(panel.urls)
    }

    func uploadFilesToDevice(_ urls: [URL]) {
        let audioURLs = deviceOperationsCoordinator.expandAudioURLs(urls)
        guard !audioURLs.isEmpty else {
            appendLog("No compatible music files were selected.")
            return
        }
        guard prepareDeviceBrowserForUpload() else { return }
        guard deviceBrowser.browseMode == .musicOnly else {
            appendLog("Switch the Garmin browser back to Music before adding tracks.")
            return
        }

        isManagingDeviceFiles = true
        let uploadFiles = deviceOperationsCoordinator.makeUploadFiles(
            urls: audioURLs,
            backendKind: deviceBrowser.backendKind
        )
        deviceFileTask = Task {
            defer { isManagingDeviceFiles = false }
            let result = await deviceBrowser.upload(uploadFiles)
            if let result {
                appendLog(result.message ?? "Uploaded \(result.completedCount) file(s) to Garmin.")
            } else if let error = deviceBrowser.lastError {
                appendLog("Upload failed: \(error)")
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
        }
    }

    func uploadSelectedTracksToDevice() {
        guard !syncableTracks.isEmpty else {
            appendLog("No selected compatible Mac tracks to send.")
            return
        }
        guard prepareDeviceBrowserForUpload() else { return }
        guard deviceBrowser.browseMode == .musicOnly else {
            appendLog("Switch the Garmin browser back to Music before adding tracks.")
            return
        }

        isManagingDeviceFiles = true
        let preparedTracks = syncCoordinator.preparedTracks(syncableTracks, settings: syncSettings)
        deviceFileTask = Task {
            defer { isManagingDeviceFiles = false }

            if deviceBrowser.backendKind == .mtp {
                await deviceBrowser.refresh(force: true)
                syncLegacyDeviceSnapshot()
                let plan = MTPSyncPlanner.buildPlan(
                    tracks: preparedTracks,
                    playlistName: playlistName,
                    settings: syncSettings,
                    deviceFiles: deviceBrowser.files
                )
                if plan.transferCount == 0 {
                    appendLog("All selected track(s) are already on the Garmin.")
                    updateDuplicateFlags()
                    return
                }
                let result = await syncCoordinator.executeMTPPlan(plan, deviceBrowser: deviceBrowser) { [weak self] _, message in
                    Task { @MainActor in
                        if let message { self?.appendLog(message) }
                    }
                }
                if result.failedCount > 0 {
                    appendLog("Sent \(result.uploadedCount) track(s); skipped \(result.skippedCount); \(result.failedCount) failed.")
                } else {
                    appendLog("Sent \(result.uploadedCount) track(s) to Garmin. Skipped \(result.skippedCount) identical file(s).")
                }
            } else {
                let uploadFiles = deviceOperationsCoordinator.makeUploadFiles(
                    tracks: preparedTracks,
                    playlistName: playlistName,
                    settings: syncSettings,
                    backendKind: deviceBrowser.backendKind
                )
                if let result = await deviceBrowser.upload(uploadFiles) {
                    appendLog(result.message ?? "Sent \(result.completedCount) selected track(s) to Garmin.")
                } else if let error = deviceBrowser.lastError {
                    appendLog("Send to Garmin failed: \(error)")
                }
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
        }
    }

    func openAppleMusicBrowser() {
        showAppleMusicBrowser = true
        if case .loaded = musicLibraryStatus { return }
        loadAppleMusicLibrary()
    }

    func loadAppleMusicLibrary() {
        musicLibraryStatus = .loading
        Task {
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) { [appleMusic] in
                    try appleMusic.loadSnapshot()
                }.value
                musicLibrary = snapshot
                musicLibraryStatus = .loaded(
                    playlistCount: snapshot.playlists.count,
                    albumCount: snapshot.albums.count,
                    trackCount: snapshot.tracksByID.count
                )
                appendLog("Loaded Apple Music library: \(snapshot.playlists.count) playlists, \(snapshot.albums.count) albums.")
            } catch {
                musicLibraryStatus = .unavailable(error.localizedDescription)
                appendLog("Apple Music load failed: \(error.localizedDescription)")
            }
        }
    }

    func importLibraryTracks(_ trackIDs: [String]) {
        let urls = musicLibrary.importableURLs(for: trackIDs)
        let total = trackIDs.count
        let skipped = total - urls.count
        guard !urls.isEmpty else {
            appendLog("No importable local files in selection (\(skipped) cloud-only or DRM-protected).")
            return
        }
        if skipped > 0 {
            appendLog("Skipping \(skipped) cloud-only/DRM track(s); importing \(urls.count).")
        }
        showAppleMusicBrowser = false
        Task { await addFiles(urls) }
    }

    func prepareAppleMusicPlaylistForSync(_ playlistID: String) {
        Task { await prepareAppleMusicPlaylistForSyncNow(playlistID) }
    }

    func prepareAppleMusicPlaylistForSyncNow(_ playlistID: String) async {
        guard let playlist = musicLibrary.playlists.first(where: { $0.id == playlistID }) else {
            appendLog("Choose an Apple Music playlist first.")
            return
        }

        let urls = musicLibrary.importableURLs(for: playlist.trackIDs)
        let skipped = playlist.trackIDs.count - urls.count
        guard !urls.isEmpty else {
            appendLog("No importable local files in \(playlist.name) (\(skipped) cloud-only or DRM-protected).")
            return
        }

        playlistName = playlist.name
        showAppleMusicBrowser = false
        await replaceTracks(with: urls)
        let skippedText = skipped > 0 ? " Skipped \(skipped) cloud-only/DRM track(s)." : ""
        appendLog("Prepared \(playlist.name) for Garmin sync with \(urls.count) local track(s).\(skippedText)")
    }

    func requestResetAppState() {
        showResetConfirmation = true
    }

    func resetAppState() {
        syncTask?.cancel()
        browseTask?.cancel()
        syncTask = nil
        browseTask = nil
        isSyncing = false
        isScanning = false
        isManagingDeviceFiles = false
        syncProgress = 0
        showSyncPreview = false
        syncPreview = nil
        searchText = ""
        tracks.removeAll()
        musicLibrary = .empty
        musicLibraryStatus = .idle
        showAppleMusicBrowser = false
        selectedDeviceFileIDs.removeAll()
        devices.removeAll()
        connectedUSBDevices.removeAll()
        selectedDevice = nil
        deviceFiles.removeAll()
        devicePlaylists.removeAll()
        storageInfo = nil
        isMTPLibraryLoaded = false
        connectedMTPDeviceName = nil
        moveTargetPath = ""
        pendingMTPMoveOriginals.removeAll()
        showMoveWithinGarminSheet = false
        showMTPMoveDeleteConfirmation = false
        destinationMode = .autoDetected
        destinationOverride = nil
        destinationWarning = nil
        settingsStore.resetAppState()
        playlistName = settingsStore.playlistName
        syncSettings = settingsStore.syncSettings
        deviceBrowser.clear(message: "App state reset. Refresh or choose a Garmin destination to start again.")
        transferLogStore.clear()
        transferLog = []
        try? AudioConverter.clearTemporaryConversions()
        Task { await MTPHelperClient.shutdownSharedHelper() }
        showResetConfirmation = false
    }

    func saveSettings() {
        settingsStore.playlistName = playlistName
        settingsStore.syncSettings = syncSettings
        settingsStore.advancedStorageExplorerEnabled = advancedStorageExplorerEnabled
        settingsStore.destructiveConfirmationMode = destructiveConfirmationMode
        settingsStore.lastDeviceBrowseMode = advancedStorageExplorerEnabled ? deviceBrowser.browseMode : .musicOnly
        settingsStore.destinationMode = destinationMode
        if destinationMode == .customFolder {
            settingsStore.saveDestination(destinationOverride)
        } else {
            settingsStore.saveDestination(nil)
        }
    }

    private func replaceTracks(with urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }

        tracks = await scanner.scanFiles(urls)
        updateDuplicateFlags()
    }

    private func mergeTracks(_ newTracks: [AudioTrack]) {
        tracks = libraryImportCoordinator.mergeTracks(existing: tracks, newTracks: newTracks)
    }

    private func appendLog(_ message: String) {
        transferLogStore.append(message)
        transferLog = transferLogStore.lines
    }

    private func configureMountedBrowser(destination: URL, displayName: String) {
        deviceLibraryCoordinator.configureMountedBrowser(
            deviceBrowser: deviceBrowser,
            destination: destination,
            displayName: displayName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
        )
    }

    private func configureMTPBrowser() {
        deviceLibraryCoordinator.configureMTPBrowser(
            deviceBrowser: deviceBrowser,
            connectedUSBDevices: connectedUSBDevices,
            connectedMTPDeviceName: connectedMTPDeviceName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
        )
    }

    private func prepareDeviceBrowserForUpload() -> Bool {
        deviceOperationsCoordinator.prepareDeviceBrowserForUpload(
            deviceBrowser: deviceBrowser,
            activeDestination: activeDestination,
            selectedDeviceName: selectedDevice?.volumeName,
            hasMTPDestination: hasMTPDestination,
            mtpDependencyStatus: mtpDependencyStatus,
            connectedUSBDevices: connectedUSBDevices,
            connectedMTPDeviceName: connectedMTPDeviceName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled,
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    private func syncLegacyDeviceSnapshot() {
        let snapshot = deviceLibraryCoordinator.syncLegacyDeviceSnapshot(
            from: deviceBrowser,
            activeDestination: activeDestination
        )
        deviceFiles = snapshot.deviceFiles
        devicePlaylists = snapshot.devicePlaylists
        storageInfo = snapshot.storageInfo
        selectedDeviceFileIDs = snapshot.selectedDeviceFileIDs
        deviceBrowseMessage = snapshot.deviceBrowseMessage
    }

    private func shouldConfirmDelete(files: [DeviceFile]) -> Bool {
        deviceOperationsCoordinator.shouldConfirmDelete(
            files: files,
            browseMode: deviceBrowser.browseMode,
            mode: destructiveConfirmationMode
        )
    }
}
