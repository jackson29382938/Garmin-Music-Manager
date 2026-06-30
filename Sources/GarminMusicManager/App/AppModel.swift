import AppKit
import Combine
import GarminMusicCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [GarminDevice] = []
    @Published var connectedUSBDevices: [GarminUSBDevice] = []
    @Published var mtpDependencyStatus = MTPDependencyStatus(homebrewURL: nil, mtpDetectURL: nil, mtpSendFileURL: nil, mtpSendTrackURL: nil)
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
    @Published var destinationOverride: URL?
    @Published var syncSettings: SyncSettings
    @Published var searchText = ""
    @Published var showSyncPreview = false
    @Published var syncPreview: SyncPreview?
    @Published var selectedDeviceFileIDs: Set<String> = []
    @Published var showDeleteConfirmation = false
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
    private let detector = DeviceDetector()
    private let scanner = MusicScanner()
    private let syncService = SyncService()
    private let mtpService = MTPCommandService()
    private let contentService = DeviceContentService()
    private let appleMusic = AppleMusicLibrary()
    private let settingsStore: SettingsStore
    private var syncTask: Task<Void, Never>?
    private var deviceBrowserCancellable: AnyCancellable?

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.playlistName = settingsStore.playlistName
        self.syncSettings = settingsStore.syncSettings
        self.destinationOverride = settingsStore.lastDestinationURL
        self.advancedStorageExplorerEnabled = settingsStore.advancedStorageExplorerEnabled
        self.destructiveConfirmationMode = settingsStore.destructiveConfirmationMode
        self.deviceBrowser.browseMode = settingsStore.advancedStorageExplorerEnabled
            ? settingsStore.lastDeviceBrowseMode
            : .musicOnly
        self.deviceBrowserCancellable = deviceBrowser.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.mtpDependencyStatus = mtpService.dependencyStatus()
        if let destination = destinationOverride {
            refreshDeviceContents(at: destination)
        }
        Task { refreshDevices() }
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
        destinationOverride ?? selectedDevice?.bestMusicDirectory
    }

    var hasMTPDestination: Bool {
        activeDestination == nil && !connectedUSBDevices.isEmpty
    }

    var canAttemptMTP: Bool {
        hasMTPDestination && mtpDependencyStatus.isReady
    }

    var destinationDescription: String {
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
        !isSyncing && !syncableTracks.isEmpty && (activeDestination != nil || canAttemptMTP)
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

    var selectedDeviceFiles: [DeviceFile] {
        deviceBrowser.selectedFiles
    }

    var canMoveSelectedDeviceFiles: Bool {
        deviceBrowser.supportsMove && !deviceBrowser.selectedFileIDs.isEmpty && !isManagingDeviceFiles
    }

    var exceedsAvailableStorage: Bool {
        guard let available = deviceBrowser.storageInfo?.availableCapacity else { return false }
        return selectedTracksByteCount > available
    }

    func refreshDevices() {
        mtpDependencyStatus = mtpService.dependencyStatus()
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
            if destinationOverride == nil, let device = selectedDevice, let musicDir = device.bestMusicDirectory {
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
        if let musicDir = device.bestMusicDirectory {
            destinationOverride = musicDir
            settingsStore.saveDestination(musicDir)
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

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Garmin Music destination folder"
        panel.message = "Select the Music folder on your Garmin watch or a test folder."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            destinationOverride = url
            settingsStore.saveDestination(url)
            configureMountedBrowser(destination: url, displayName: url.lastPathComponent)
            refreshDeviceContents(at: url)
            appendLog("Manual destination set: \(url.path)")
        }
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
        var fileURLs: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                fileURLs.append(contentsOf: scanner.findAudioFiles(in: url))
            } else {
                fileURLs.append(url)
            }
        }
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
        if isMTPLibraryMode || deviceBrowser.backendKind == .mtp {
            let index = Set(deviceBrowser.files.map { "\($0.name.lowercased())|\($0.size)" })
            tracks = tracks.map { track in
                var updated = track
                let key = "\(FileNameSanitizer.safeFileName(for: track).lowercased())|\(track.byteCount)"
                let altKey = "\(track.fileName.lowercased())|\(track.byteCount)"
                updated.isDuplicateOnDevice = index.contains(key) || index.contains(altKey)
                return updated
            }
            return
        }
        guard let destination = activeDestination else { return }
        tracks = contentService.markDuplicates(tracks: tracks, destination: destination, playlistName: playlistName)
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
            syncPreview = buildMTPPreview(tracks: syncableTracks, playlistName: playlistName, settings: syncSettings)
            showSyncPreview = true
            return
        }

        do {
            syncPreview = try syncService.buildPreview(
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
        appendLog("Sync cancelled.")
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

        isSyncing = true
        syncProgress = 0
        settingsStore.playlistName = playlistName
        settingsStore.syncSettings = syncSettings
        settingsStore.saveDestination(destination)
        appendLog("Starting sync to \(destination.path)")

        syncTask = Task {
            do {
                let result = try await syncService.sync(
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
            isSyncing = false
            syncProgress = 1
            syncTask = nil
        }
        await syncTask?.value
    }

    private func syncToMTP() async {
        guard mtpDependencyStatus.isReady else {
            appendLog(mtpDependencyStatus.message)
            return
        }

        isSyncing = true
        syncProgress = 0
        settingsStore.playlistName = playlistName
        settingsStore.syncSettings = syncSettings
        appendLog("Starting MTP sync to Garmin watch")

        syncTask = Task {
            do {
                try Task.checkCancellation()
                configureMTPBrowser()
                let uploadFiles = makeUploadFilesForMTP(tracks: syncableTracks, playlistName: playlistName, settings: syncSettings)
                let result = await deviceBrowser.upload(uploadFiles)
                syncProgress = 1
                if let result {
                    if !result.failedItems.isEmpty {
                        appendLog("MTP sync partially complete: sent \(result.completedCount) song(s), \(result.failedItems.count) failed.")
                    } else {
                        appendLog("MTP sync complete: sent \(result.completedCount) song(s) to the Garmin.")
                    }
                } else {
                    appendLog("MTP sync failed: \(deviceBrowser.lastError ?? "The Garmin helper did not complete the upload.")")
                }
                browseGarminMusicLibrary()
            } catch is CancellationError {
                appendLog("MTP sync cancelled.")
            } catch {
                appendLog("MTP sync failed: \(error.localizedDescription)")
            }
            isSyncing = false
            syncProgress = 1
            syncTask = nil
        }
        await syncTask?.value
    }

    func installMTPDependencies() {
        guard !isInstallingMTPDependencies else { return }
        isInstallingMTPDependencies = true
        appendLog("Installing portable MTP support (Homebrew/libmtp if needed)…")
        Task {
            do {
                try await mtpService.installDependencies { [weak self] message in
                    Task { @MainActor in
                        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self?.appendLog(message)
                        }
                    }
                }
                mtpDependencyStatus = mtpService.dependencyStatus()
                appendLog(mtpDependencyStatus.message)
                refreshDevices()
            } catch {
                appendLog("MTP dependency install failed: \(error.localizedDescription)")
            }
            isInstallingMTPDependencies = false
        }
    }

    func deleteSelectedDeviceFiles() {
        let files = selectedDeviceFiles
        guard !files.isEmpty else { return }

        isManagingDeviceFiles = true
        Task {
            let result = await deviceBrowser.deleteSelected()
            if let result {
                appendLog(result.message ?? "Deleted \(result.completedCount) file(s).")
            } else if let error = deviceBrowser.lastError {
                appendLog("Delete failed: \(error)")
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
            isManagingDeviceFiles = false
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
        Task {
            let result = await deviceBrowser.copySelected(to: destination)
            if let result {
                appendLog(result.message ?? "Copied \(result.completedCount) file(s) to \(destination.path).")
            } else if let error = deviceBrowser.lastError {
                appendLog("Copy failed: \(error)")
            }
            isManagingDeviceFiles = false
        }
    }

    func moveSelectedDeviceFiles() {
        let files = selectedDeviceFiles
        guard !files.isEmpty else { return }

        guard deviceBrowser.supportsMove else {
            appendLog("Moving files directly on Garmin MTP is not supported by this watch connection. Copy files to the Mac or delete them, then re-sync to the desired playlist/folder.")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose destination folder"
        panel.message = "Select where to move the selected files."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if let activeDestination {
            panel.directoryURL = activeDestination
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isManagingDeviceFiles = true
        Task {
            let result = await deviceBrowser.moveSelected(to: destination)
            if let result {
                appendLog(result.message ?? "Moved \(result.completedCount) file(s) to \(destination.path).")
            } else if let error = deviceBrowser.lastError {
                appendLog("Move failed: \(error)")
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
            isManagingDeviceFiles = false
        }
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
            isBrowsingDevice = false
            browseTask = nil
        }
    }

    func switchDeviceBrowseMode(to mode: DeviceBrowseMode) {
        deviceBrowser.setBrowseMode(mode, advancedEnabled: advancedStorageExplorerEnabled)
        settingsStore.lastDeviceBrowseMode = deviceBrowser.browseMode
        Task {
            await deviceBrowser.refresh(force: false)
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
        var audioURLs: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                audioURLs.append(contentsOf: scanner.findAudioFiles(in: url))
            } else if MusicScanner.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                audioURLs.append(url)
            }
        }
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
        let uploadFiles = makeUploadFilesForDeviceBrowser(urls: audioURLs)
        Task {
            let result = await deviceBrowser.upload(uploadFiles)
            if let result {
                appendLog(result.message ?? "Uploaded \(result.completedCount) file(s) to Garmin.")
            } else if let error = deviceBrowser.lastError {
                appendLog("Upload failed: \(error)")
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
            isManagingDeviceFiles = false
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
        let uploadFiles = makeUploadFilesForDeviceBrowser(
            tracks: syncableTracks,
            playlistName: playlistName,
            settings: syncSettings
        )
        Task {
            let result = await deviceBrowser.upload(uploadFiles)
            if let result {
                appendLog(result.message ?? "Sent \(result.completedCount) selected track(s) to Garmin.")
            } else if let error = deviceBrowser.lastError {
                appendLog("Send to Garmin failed: \(error)")
            }
            syncLegacyDeviceSnapshot()
            updateDuplicateFlags()
            isManagingDeviceFiles = false
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

    func saveSettings() {
        settingsStore.playlistName = playlistName
        settingsStore.syncSettings = syncSettings
        settingsStore.advancedStorageExplorerEnabled = advancedStorageExplorerEnabled
        settingsStore.destructiveConfirmationMode = destructiveConfirmationMode
        settingsStore.lastDeviceBrowseMode = advancedStorageExplorerEnabled ? deviceBrowser.browseMode : .musicOnly
        if let destination = activeDestination {
            settingsStore.saveDestination(destination)
        }
    }

    private func mergeTracks(_ newTracks: [AudioTrack]) {
        var existing = Set(tracks.map { $0.url })
        for track in newTracks where !existing.contains(track.url) {
            tracks.append(track)
            existing.insert(track.url)
        }
        tracks.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func appendLog(_ message: String) {
        transferLog.append(LogFormatter.timestamped(message))
    }

    private func configureMountedBrowser(destination: URL, displayName: String) {
        deviceBrowser.configure(backend: MountedFolderDeviceFileSystem(rootURL: destination, displayName: displayName))
        if deviceBrowser.browseMode == .advancedStorage && !advancedStorageExplorerEnabled {
            deviceBrowser.setBrowseMode(.musicOnly, advancedEnabled: false)
        }
    }

    private func configureMTPBrowser() {
        let device = connectedUSBDevices.first
        let deviceName = connectedMTPDeviceName ?? device?.displayName ?? "Garmin watch"
        let deviceID = device?.dedupeKey ?? deviceName
        deviceBrowser.configure(backend: MTPDeviceFileSystem(deviceID: deviceID, displayName: deviceName))
        if deviceBrowser.browseMode == .advancedStorage && !advancedStorageExplorerEnabled {
            deviceBrowser.setBrowseMode(.musicOnly, advancedEnabled: false)
        }
    }

    private func prepareDeviceBrowserForUpload() -> Bool {
        if deviceBrowser.isConfigured {
            return true
        }
        if let destination = activeDestination {
            configureMountedBrowser(destination: destination, displayName: selectedDevice?.volumeName ?? destination.lastPathComponent)
            return true
        }
        if hasMTPDestination {
            guard mtpDependencyStatus.isReady else {
                appendLog(mtpDependencyStatus.message)
                return false
            }
            configureMTPBrowser()
            return true
        }
        appendLog("Connect a Garmin or choose a destination folder before sending music.")
        return false
    }

    private func syncLegacyDeviceSnapshot() {
        deviceFiles = deviceBrowser.files.map { file in
            DeviceAudioFile(
                id: file.id,
                url: legacyURL(for: file),
                fileName: file.name,
                byteCount: file.size,
                modifiedDate: file.modifiedDate,
                folderName: file.locationDescription,
                mtpFileID: file.backendKind == .mtp ? file.objectID : nil,
                mtpTrackID: file.backendKind == .mtp ? file.objectID : nil
            )
        }
        devicePlaylists = deviceBrowser.collections
            .filter { $0.kind == .playlist }
            .map { collection in
                DevicePlaylist(
                    id: collection.id,
                    name: collection.name,
                    trackFileNames: deviceBrowser.files
                        .filter { collection.fileIDs.contains($0.id) }
                        .map(\.name) + collection.unmatchedItems,
                    source: .mtpPlaylist
                )
            }
        storageInfo = deviceBrowser.storageInfo.map { info in
            StorageInfo(
                totalCapacity: info.totalCapacity,
                availableCapacity: info.availableCapacity,
                usedByAudioFiles: info.usedByFiles,
                audioFileCount: info.fileCount
            )
        }
        selectedDeviceFileIDs = deviceBrowser.selectedFileIDs
        deviceBrowseMessage = deviceBrowser.statusMessage
    }

    private func legacyURL(for file: DeviceFile) -> URL {
        if file.backendKind == .mountedFolder, let activeDestination {
            return activeDestination.appendingPathComponent(file.path)
        }
        if let objectID = file.objectID, let url = URL(string: "mtp://file/\(objectID)") {
            return url
        }
        return URL(fileURLWithPath: file.name)
    }

    private func shouldConfirmDelete(files: [DeviceFile]) -> Bool {
        if deviceBrowser.browseMode == .advancedStorage, files.contains(where: { !$0.isInMusicArea }) {
            return true
        }
        switch destructiveConfirmationMode {
        case .always:
            return true
        case .batchesOnly:
            return files.count > 1
        case .never:
            return false
        }
    }

    private func buildMTPPreview(tracks: [AudioTrack], playlistName: String, settings: SyncSettings) -> SyncPreview {
        let uploadFiles = makeUploadFilesForMTP(tracks: tracks, playlistName: playlistName, settings: settings)
        let items = zip(tracks, uploadFiles).map { track, uploadFile in
            SyncPreviewItem(
                track: track,
                action: .copy,
                targetPath: "Garmin MTP/\(uploadFile.remotePath)"
            )
        }
        return SyncPreview(
            items: items,
            totalBytesToCopy: tracks.reduce(Int64(0)) { $0 + $1.byteCount }
        )
    }

    private func makeUploadFilesForMTP(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings
    ) -> [DeviceUploadFile] {
        let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
        return tracks.map { track in
            let relativePath = uploadRelativePath(for: track, playlistName: cleanPlaylistName, settings: settings)
            return DeviceUploadFile(
                localPath: track.url.path,
                remotePath: "Music/\(relativePath)",
                displayName: track.displayName,
                metadata: DeviceAudioMetadata(
                    title: track.title,
                    artist: track.artist,
                    album: track.album ?? cleanPlaylistName,
                    durationSeconds: track.durationSeconds
                )
            )
        }
    }

    private func makeUploadFilesForDeviceBrowser(urls: [URL]) -> [DeviceUploadFile] {
        urls.map { url in
            let remotePath: String
            if deviceBrowser.backendKind == .mtp {
                remotePath = "Music/\(FileNameSanitizer.sanitizeFileName(url.lastPathComponent, fallback: "Track"))"
            } else {
                remotePath = FileNameSanitizer.sanitizeFileName(url.lastPathComponent, fallback: "Track")
            }
            return DeviceUploadFile(
                localPath: url.path,
                remotePath: remotePath,
                displayName: url.lastPathComponent,
                metadata: DeviceAudioMetadata(title: url.deletingPathExtension().lastPathComponent)
            )
        }
    }

    private func makeUploadFilesForDeviceBrowser(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings
    ) -> [DeviceUploadFile] {
        let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
        return tracks.map { track in
            let relativePath = uploadRelativePath(for: track, playlistName: cleanPlaylistName, settings: settings)
            let remotePath = deviceBrowser.backendKind == .mtp ? "Music/\(relativePath)" : relativePath
            return DeviceUploadFile(
                localPath: track.url.path,
                remotePath: remotePath,
                displayName: track.displayName,
                metadata: DeviceAudioMetadata(
                    title: track.title,
                    artist: track.artist,
                    album: track.album ?? cleanPlaylistName,
                    durationSeconds: track.durationSeconds
                )
            )
        }
    }

    private func uploadRelativePath(for track: AudioTrack, playlistName: String, settings: SyncSettings) -> String {
        var components: [String] = [playlistName]
        switch settings.organizationPolicy {
        case .flat:
            break
        case .byArtist:
            if let artist = track.artist?.nilIfEmpty {
                components.append(FileNameSanitizer.sanitizePathComponent(artist))
            }
        case .byArtistAlbum:
            components.append(contentsOf: track.organizationFolderComponents)
        }
        components.append(FileNameSanitizer.safeFileName(for: track))
        return components.joined(separator: "/")
    }

    private func copyDeviceFiles(_ files: [DeviceAudioFile], to destinationFolder: URL) throws -> Int {
        var copied = 0
        for file in files {
            let targetURL = FileNameSanitizer.uniqueURL(
                in: destinationFolder,
                preferredFileName: file.fileName
            )
            try FileManager.default.copyItem(at: file.url, to: targetURL)
            copied += 1
        }
        return copied
    }

    private func moveDeviceFiles(_ files: [DeviceAudioFile], to destinationFolder: URL) throws -> Int {
        var moved = 0
        for file in files {
            let targetURL = FileNameSanitizer.uniqueURL(
                in: destinationFolder,
                preferredFileName: file.fileName
            )
            try FileManager.default.moveItem(at: file.url, to: targetURL)
            moved += 1
        }
        return moved
    }
}
