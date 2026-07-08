import AppKit
import Combine
import GarminMusicCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [GarminDevice] = []
    @Published var connectedUSBDevices: [GarminUSBDevice] = []
    @Published var mtpDependencyStatus = MTPDependencyStatus.unavailable
    @Published var isInstallingMTPDependencies = false
    @Published var selectedDevice: GarminDevice?
    @Published var tracks: [AudioTrack] = []
    @Published var transferLog: [String] = []
    @Published var isSyncing = false
    @Published var isScanning = false
    @Published var isManagingDeviceFiles = false
    @Published var syncProgress: Double = 0
    @Published var playlistName: String {
        didSet { persistSettingsIfReady() }
    }
    @Published var destinationMode: GarminDestinationMode {
        didSet { persistSettingsIfReady() }
    }
    @Published var destinationOverride: URL?
    @Published var destinationWarning: String?
    @Published var syncSettings: SyncSettings {
        didSet { persistSettingsIfReady() }
    }
    @Published var searchText = ""
    @Published var showSyncPreview = false
    @Published var syncPreview: SyncPreview?
    @Published var showDeleteConfirmation = false
    @Published var showResetConfirmation = false
    @Published var showMoveWithinGarminSheet = false
    @Published var moveTargetPath = ""
    @Published var showMTPMoveDeleteConfirmation = false
    @Published var advancedStorageExplorerEnabled: Bool {
        didSet {
            if !advancedStorageExplorerEnabled {
                deviceBrowser.setBrowseMode(.musicOnly, advancedEnabled: false)
                Task { await deviceBrowser.refresh(force: false) }
            }
            persistSettingsIfReady()
        }
    }
    @Published var destructiveConfirmationMode: DestructiveConfirmationMode {
        didSet { persistSettingsIfReady() }
    }

    /// Suppresses auto-persist while `init` / reset assign multiple properties.
    private var isPersistingSettings = false
    private var settingsReady = false

    @Published var showAppleMusicBrowser = false
    @Published var musicLibrary: MusicLibrarySnapshot = .empty
    @Published var musicLibraryStatus: MusicLibraryStatus = .idle

    @Published var isBrowsingDevice = false
    @Published var connectedMTPDeviceName: String?
    @Published var deviceBrowser = DeviceBrowserStore()
    /// Track IDs from the last MTP transfer that failed (for Retry Failed).
    @Published private(set) var lastFailedTrackIDs: Set<UUID> = []

    private let detector = DeviceDetector()
    private let syncSession = SyncSessionController()
    private let deviceSession = DeviceSessionController()
    private let macLibrarySession = MacLibrarySession()
    private let mtpDependencyManager = MTPDependencyManager()
    private let transferLogStore = TransferLogStore()
    private let settingsStore: SettingsStore
    private var deviceBrowserCancellable: AnyCancellable?
    private var transferLogCancellable: AnyCancellable?
    private var tracksPersistCancellable: AnyCancellable?
    private var connectMonitor: DeviceConnectMonitor?

    /// True when the device browser has loaded any MTP listing (files or collections).
    var isMTPLibraryLoaded: Bool {
        deviceBrowser.backendKind == .mtp
            && (!deviceBrowser.files.isEmpty || !deviceBrowser.collections.isEmpty)
    }

    /// Convenience for views/log; backed by `deviceBrowser.statusMessage`.
    var deviceBrowseMessage: String? {
        get { deviceBrowser.statusMessage }
        set { deviceBrowser.statusMessage = newValue }
    }

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
        self.settingsReady = true
        self.tracksPersistCancellable = $tracks
            .dropFirst()
            .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
            .sink { [weak self] tracks in
                self?.macLibrarySession.saveQueue(tracks)
            }
        if autoRefresh {
            if let destination = destinationOverride {
                refreshDeviceContents(at: destination)
            }
            Task { refreshDevices() }
            Task { await self.restoreLibraryQueueIfNeeded() }
            let monitor = DeviceConnectMonitor { [weak self] in
                self?.refreshDevices()
            }
            monitor.start()
            self.connectMonitor = monitor
        }
    }

    var canRetryFailedTransfers: Bool {
        !isSyncing
            && !lastFailedTrackIDs.isEmpty
            && tracks.contains { lastFailedTrackIDs.contains($0.id) && $0.compatibility.canCopy }
    }

    var syncableTracks: [AudioTrack] {
        macLibrarySession.syncableTracks(from: tracks)
    }

    var blockedTracks: [AudioTrack] {
        macLibrarySession.blockedTracks(from: tracks)
    }

    var filteredTracks: [AudioTrack] {
        macLibrarySession.filteredTracks(from: tracks, searchText: searchText)
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
        macLibrarySession.macLibraryLocationDescription(for: tracks)
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
                if activeDestination == nil {
                    deviceBrowser.clear(message: "Connect a Garmin over USB, then refresh to browse files on the watch.")
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
                    deviceBrowser.statusMessage = mtpDependencyStatus.message
                    appendLog(mtpDependencyStatus.message)
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
        persistSettingsIfReady(force: true)
        if let musicDir = device.bestMusicDirectory {
            configureMountedBrowser(destination: musicDir, displayName: device.volumeName)
            refreshDeviceContents(at: musicDir)
            appendLog("Selected device: \(device.volumeName)")
        }
    }

    func chooseMusicFiles() {
        macLibrarySession.chooseMusicFiles { [weak self] urls in
            Task { await self?.addFiles(urls) }
        }
    }

    func chooseMusicFolder() {
        macLibrarySession.chooseMusicFolder { [weak self] urls in
            Task { await self?.addFiles(urls) }
        }
    }

    /// Import local tracks referenced by an `.m3u` / `.m3u8` playlist file.
    /// Import local tracks referenced by an `.m3u` / `.m3u8` playlist file.
    func chooseM3UPlaylist() {
        guard let url = macLibrarySession.chooseM3UPlaylistURL() else { return }
        Task { await importM3UPlaylist(from: url) }
    }

    func importM3UPlaylist(from url: URL) async {
        let name = url.deletingPathExtension().lastPathComponent
        if !name.isEmpty {
            playlistName = name
        }
        await addFiles([url])
    }

    func useAutoDetectedDestination() {
        destinationMode = .autoDetected
        destinationOverride = nil
        destinationWarning = nil
        persistSettingsIfReady(force: true)

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
        persistSettingsIfReady(force: true)
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
        let result = await macLibrarySession.addFiles(
            urls,
            into: tracks,
            setScanning: { [weak self] value in self?.isScanning = value }
        )
        tracks = result.tracks
        updateDuplicateFlags()
        if result.addedCount > 0 {
            var message = result.message ?? "Added \(result.addedCount) file(s)."
            if !message.contains("selected and ready") {
                message += " \(syncableTracks.count) selected and ready."
            }
            appendLog(message)
        } else if let message = result.message {
            appendLog(message)
        }
    }

    func handleDroppedURLs(_ urls: [URL]) {
        Task { await addFiles(urls) }
    }

    func removeTracks(at offsets: IndexSet) {
        tracks = macLibrarySession.removeTracks(at: offsets, filtered: filteredTracks, from: tracks)
    }

    func clearTracks() {
        tracks.removeAll()
        lastFailedTrackIDs = []
        macLibrarySession.clearPersistedQueue()
        appendLog("Cleared all tracks.")
    }

    private func restoreLibraryQueueIfNeeded() async {
        guard tracks.isEmpty else { return }
        guard let result = await macLibrarySession.restoreQueue(
            setScanning: { [weak self] value in self?.isScanning = value }
        ) else { return }
        tracks = result.tracks
        updateDuplicateFlags()
        if let message = result.message {
            appendLog(message)
        }
    }

    func selectAllReady() {
        tracks = macLibrarySession.selectAllReady(in: tracks)
    }

    func deselectAll() {
        tracks = macLibrarySession.deselectAll(in: tracks)
    }

    func refreshDeviceContents(at destination: URL? = nil) {
        guard let destination = destination ?? activeDestination else {
            if canAttemptMTP {
                browseGarminMusicLibrary()
                return
            }
            deviceBrowser.clear(message: "Connect a Garmin over USB or choose a destination folder to browse existing audio files.")
            return
        }
        deviceSession.refreshMountedContents(
            deviceBrowser: deviceBrowser,
            destination: destination,
            displayName: selectedDevice?.volumeName ?? destination.lastPathComponent,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled,
            onFinished: { [weak self] in self?.updateDuplicateFlags() }
        )
    }

    func updateDuplicateFlags() {
        tracks = deviceSession.updateDuplicateFlags(
            tracks: tracks,
            deviceBrowser: deviceBrowser,
            activeDestination: activeDestination,
            isMTPLibraryMode: isMTPLibraryMode,
            playlistName: playlistName,
            syncSettings: syncSettings
        )
    }

    func prepareSyncPreview() {
        guard !syncableTracks.isEmpty else {
            appendLog("Nothing to sync. Add compatible selected files first.")
            return
        }
        do {
            syncPreview = try syncSession.buildPreview(
                tracks: syncableTracks,
                playlistName: playlistName,
                settings: syncSettings,
                activeDestination: activeDestination,
                deviceFiles: deviceBrowser.files,
                mtpReady: mtpDependencyStatus.isReady
            )
            showSyncPreview = true
        } catch let error as SyncSessionError {
            switch error {
            case .mtpNotReady:
                appendLog(mtpDependencyStatus.message)
            }
        } catch {
            appendLog("Preview failed: \(error.localizedDescription)")
        }
    }

    func confirmSync() {
        showSyncPreview = false
        Task { await sync() }
    }

    func cancelSync() {
        isSyncing = false
        syncSession.cancel()
        appendLog("Sync cancelled.")
    }

    /// Cancels the in-flight device browse or file operation (refresh, upload,
    /// copy, delete, move). Over MTP this asks the helper to abort the current
    /// libmtp transfer (SIGUSR1), escalating to process kill if needed.
    func cancelDeviceOperation() {
        deviceSession.cancelInFlight()
        appendLog("Device operation cancelled.")
    }

    func sync() async {
        guard !syncableTracks.isEmpty else {
            appendLog("Nothing to sync.")
            return
        }

        isSyncing = true
        syncProgress = 0
        persistSettingsIfReady(force: true)

        defer {
            isSyncing = false
            syncProgress = 1
        }

        await syncSession.run(
            tracks: syncableTracks,
            playlistName: playlistName,
            settings: syncSettings,
            activeDestination: activeDestination,
            mtpReady: mtpDependencyStatus.isReady,
            mtpNotReadyMessage: mtpDependencyStatus.message,
            deviceBrowser: deviceBrowser,
            configureMTP: { [weak self] in self?.configureMTPBrowser() },
            onProgress: { [weak self] progress, message in
                self?.syncProgress = progress
                if let message { self?.appendLog(message) }
            },
            onLog: { [weak self] message in
                self?.appendLog(message)
            },
            onMountedComplete: { [weak self] destination in
                self?.lastFailedTrackIDs = []
                self?.refreshDeviceContents(at: destination)
            },
            onMTPComplete: { [weak self] result in
                self?.lastFailedTrackIDs = Set(result.failedTrackIDs)
                self?.applyPostMTPTransferUI(forceLibraryRefresh: false)
            }
        )
    }

    /// Re-selects only tracks that failed the last MTP transfer and starts a new sync.
    /// Re-selects only tracks that failed the last MTP transfer and starts a new sync.
    func retryFailedTransfers() {
        guard canRetryFailedTransfers else {
            appendLog("Nothing to retry.")
            return
        }
        tracks = macLibrarySession.selectOnly(ids: lastFailedTrackIDs, in: tracks)
        let count = tracks.filter { $0.isSelected }.count
        appendLog("Retrying \(count) failed track(s)…")
        prepareSyncPreview()
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
        deviceSession.deleteSelected(
            deviceBrowser: deviceBrowser,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            onFinished: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    func requestDeleteSelectedDeviceFiles() {
        let files = selectedDeviceFiles
        guard !files.isEmpty else { return }
        if deviceSession.shouldConfirmDelete(
            files: files,
            browseMode: deviceBrowser.browseMode,
            mode: destructiveConfirmationMode
        ) {
            showDeleteConfirmation = true
        } else {
            deleteSelectedDeviceFiles()
        }
    }

    func copySelectedDeviceFilesToMac() {
        deviceSession.copySelectedToMac(
            deviceBrowser: deviceBrowser,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            log: { [weak self] message in self?.appendLog(message) }
        )
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
        showMoveWithinGarminSheet = false
        moveTargetPath = deviceSession.moveSelectedWithinGarmin(
            deviceBrowser: deviceBrowser,
            path: path,
            playlistName: playlistName,
            activeDestination: activeDestination,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            setShowMTPMoveDeleteConfirmation: { [weak self] value in self?.showMTPMoveDeleteConfirmation = value },
            onFinished: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    func confirmDeleteOriginalsAfterMTPMove() {
        deviceSession.confirmDeleteOriginalsAfterMTPMove(
            deviceBrowser: deviceBrowser,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            setShowConfirmation: { [weak self] value in self?.showMTPMoveDeleteConfirmation = value },
            onFinished: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    func cancelDeleteOriginalsAfterMTPMove() {
        deviceSession.cancelDeleteOriginalsAfterMTPMove(
            setShowConfirmation: { [weak self] value in self?.showMTPMoveDeleteConfirmation = value },
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    func defaultMoveTargetPath() -> String {
        deviceSession.defaultMoveTargetPath(playlistName: playlistName)
    }

    func normalizedMoveTargetPath(_ path: String) -> String {
        deviceSession.normalizedMoveTargetPath(path, playlistName: playlistName)
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
    func browseGarminMusicLibrary(force: Bool = true) {
        deviceSession.browseMTPLibrary(
            deviceBrowser: deviceBrowser,
            force: force,
            hasMTPDestination: hasMTPDestination,
            mtpReady: mtpDependencyStatus.isReady,
            mtpMessage: mtpDependencyStatus.message,
            connectedUSBDevices: connectedUSBDevices,
            connectedMTPDeviceName: connectedMTPDeviceName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled,
            isBrowsingDevice: isBrowsingDevice,
            isManagingDeviceFiles: isManagingDeviceFiles,
            setBrowsing: { [weak self] value in self?.isBrowsingDevice = value },
            setConnectedMTPDeviceName: { [weak self] value in self?.connectedMTPDeviceName = value },
            onDuplicates: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    /// Updates duplicate flags / connected name after an MTP transfer without a full re-list.
    private func applyPostMTPTransferUI(forceLibraryRefresh: Bool, logSummary: Bool = true) {
        if forceLibraryRefresh {
            browseGarminMusicLibrary(force: true)
            return
        }
        deviceSession.applyPostTransferUI(
            deviceBrowser: deviceBrowser,
            logSummary: logSummary,
            setConnectedMTPDeviceName: { [weak self] value in self?.connectedMTPDeviceName = value },
            onDuplicates: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    func switchDeviceBrowseMode(to mode: DeviceBrowseMode) {
        deviceSession.switchBrowseMode(
            deviceBrowser: deviceBrowser,
            mode: mode,
            advancedEnabled: advancedStorageExplorerEnabled,
            onBrowseModePersisted: { [weak self] browseMode in
                self?.settingsStore.lastDeviceBrowseMode = browseMode
            },
            onFinished: { [weak self] in self?.updateDuplicateFlags() }
        )
    }

    func chooseFilesToUploadToDevice() {
        deviceSession.chooseAndUploadFiles(
            deviceBrowser: deviceBrowser,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            onFinished: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    func uploadFilesToDevice(_ urls: [URL]) {
        guard prepareDeviceBrowserForUpload() else { return }
        deviceSession.uploadFiles(
            urls,
            deviceBrowser: deviceBrowser,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            onFinished: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.appendLog(message) }
        )
    }

    /// Sends selected Mac tracks using the **same** engine as Sync Playlist
    /// (`sync()` → `SyncSessionController.run`). Skips the preview sheet only.
    func uploadSelectedTracksToDevice() {
        guard !syncableTracks.isEmpty else {
            appendLog("No selected compatible Mac tracks to send.")
            return
        }
        guard canUploadSelectedTracksToDevice else {
            if let reason = uploadDisabledReason {
                appendLog(reason)
            }
            return
        }
        guard prepareDeviceBrowserForUpload() else { return }
        appendLog("Sending selected tracks (same path as Sync Playlist)…")
        Task { await sync() }
    }

    func openAppleMusicBrowser() {
        showAppleMusicBrowser = true
        if case .loaded = musicLibraryStatus { return }
        loadAppleMusicLibrary()
    }

    func loadAppleMusicLibrary() {
        musicLibraryStatus = .loading
        Task {
            switch await macLibrarySession.loadAppleMusicLibrary() {
            case .loaded(let snapshot, let message):
                musicLibrary = snapshot
                musicLibraryStatus = .loaded(
                    playlistCount: snapshot.playlists.count,
                    albumCount: snapshot.albums.count,
                    trackCount: snapshot.tracksByID.count
                )
                appendLog(message)
            case .failed(let message):
                let detail = message.replacingOccurrences(of: "Apple Music load failed: ", with: "")
                musicLibraryStatus = .unavailable(detail)
                appendLog(message)
            }
        }
    }

    func importLibraryTracks(_ trackIDs: [String]) {
        let plan = macLibrarySession.planImportLibraryTracks(trackIDs: trackIDs, musicLibrary: musicLibrary)
        for line in plan.logMessages {
            appendLog(line)
        }
        guard !plan.urls.isEmpty else { return }
        if plan.closeBrowser {
            showAppleMusicBrowser = false
        }
        Task { await addFiles(plan.urls) }
    }

    func prepareAppleMusicPlaylistForSync(_ playlistID: String) {
        Task { await prepareAppleMusicPlaylistForSyncNow(playlistID) }
    }

    func prepareAppleMusicPlaylistForSyncNow(_ playlistID: String) async {
        let plan = macLibrarySession.planAppleMusicPlaylist(playlistID: playlistID, musicLibrary: musicLibrary)
        for line in plan.logMessages {
            appendLog(line)
        }
        guard !plan.urls.isEmpty else { return }
        if let name = plan.playlistName {
            playlistName = name
        }
        if plan.closeBrowser {
            showAppleMusicBrowser = false
        }
        if plan.replaceQueue {
            await replaceTracks(with: plan.urls)
        } else {
            await addFiles(plan.urls)
        }
    }

    func requestResetAppState() {
        showResetConfirmation = true
    }

    func resetAppState() {
        syncSession.cancel()
        deviceSession.reset()
        isSyncing = false
        isScanning = false
        isManagingDeviceFiles = false
        syncProgress = 0
        showSyncPreview = false
        syncPreview = nil
        searchText = ""
        tracks.removeAll()
        lastFailedTrackIDs = []
        macLibrarySession.clearPersistedQueue()
        musicLibrary = .empty
        musicLibraryStatus = .idle
        showAppleMusicBrowser = false
        deviceBrowser.selectedFileIDs.removeAll()
        devices.removeAll()
        connectedUSBDevices.removeAll()
        selectedDevice = nil
        connectedMTPDeviceName = nil
        moveTargetPath = ""
        showMoveWithinGarminSheet = false
        showMTPMoveDeleteConfirmation = false
        destinationMode = .autoDetected
        destinationOverride = nil
        destinationWarning = nil
        settingsStore.resetAppState()
        settingsReady = false
        playlistName = settingsStore.playlistName
        syncSettings = settingsStore.syncSettings
        settingsReady = true
        deviceBrowser.clear(message: "App state reset. Refresh or choose a Garmin destination to start again.")
        transferLogStore.clear()
        transferLog = []
        try? AudioConverter.clearTemporaryConversions()
        Task { await MTPHelperClient.shutdownSharedHelper() }
        showResetConfirmation = false
    }

    func saveSettings() {
        persistSettingsIfReady(force: true)
    }

    private func persistSettingsIfReady(force: Bool = false) {
        guard settingsReady || force else { return }
        guard !isPersistingSettings else { return }
        isPersistingSettings = true
        defer { isPersistingSettings = false }

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
        let result = await macLibrarySession.replaceTracks(
            with: urls,
            setScanning: { [weak self] value in self?.isScanning = value }
        )
        tracks = result.tracks
        updateDuplicateFlags()
    }

    private func appendLog(_ message: String) {
        transferLogStore.append(message)
        transferLog = transferLogStore.lines
    }

    /// Logs conversion outcomes so missing ffmpeg / failed encodes are never silent.
    private func logTrackPreparation(_ preparation: TrackPreparationResult) {
        if preparation.convertedCount > 0 {
            appendLog("Converted \(preparation.convertedCount) track(s) to AAC for Garmin.")
        }
        for failure in preparation.conversionFailures {
            appendLog(failure)
        }
    }

    private func configureMountedBrowser(destination: URL, displayName: String) {
        deviceSession.configureMountedBrowser(
            deviceBrowser: deviceBrowser,
            destination: destination,
            displayName: displayName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
        )
    }

    private func configureMTPBrowser() {
        deviceSession.configureMTPBrowser(
            deviceBrowser: deviceBrowser,
            connectedUSBDevices: connectedUSBDevices,
            connectedMTPDeviceName: connectedMTPDeviceName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
        )
    }

    private func prepareDeviceBrowserForUpload() -> Bool {
        deviceSession.prepareDeviceBrowserForUpload(
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
}
