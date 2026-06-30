import AppKit
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

    @Published var showAppleMusicBrowser = false
    @Published var musicLibrary: MusicLibrarySnapshot = .empty
    @Published var musicLibraryStatus: MusicLibraryStatus = .idle

    @Published var isBrowsingDevice = false
    @Published var isMTPLibraryLoaded = false
    @Published var devicePlaylists: [DevicePlaylist] = []
    @Published var connectedMTPDeviceName: String?
    @Published var deviceBrowseMessage: String?

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

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.playlistName = settingsStore.playlistName
        self.syncSettings = settingsStore.syncSettings
        self.destinationOverride = settingsStore.lastDestinationURL
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

    var selectedDeviceFiles: [DeviceAudioFile] {
        deviceFiles.filter { selectedDeviceFileIDs.contains($0.id) }
    }

    var canMoveSelectedDeviceFiles: Bool {
        activeDestination != nil && !selectedDeviceFileIDs.isEmpty && !isManagingDeviceFiles
    }

    var exceedsAvailableStorage: Bool {
        guard let available = storageInfo?.availableCapacity else { return false }
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
                    deviceFiles = []
                    devicePlaylists = []
                    storageInfo = nil
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
                if mtpDependencyStatus.isReady {
                    browseGarminMusicLibrary()
                } else {
                    deviceBrowseMessage = mtpDependencyStatus.message
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
            deviceFiles = []
            devicePlaylists = []
            storageInfo = nil
            deviceBrowseMessage = "Connect a Garmin over USB or choose a destination folder to browse existing audio files."
            return
        }
        deviceFiles = contentService.listAudioFiles(in: destination)
        devicePlaylists = []
        storageInfo = contentService.storageInfo(for: destination)
        deviceBrowseMessage = nil
        updateDuplicateFlags()
    }

    func updateDuplicateFlags() {
        if isMTPLibraryMode {
            let index = Set(deviceFiles.map { "\($0.fileName.lowercased())|\($0.byteCount)" })
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
            syncPreview = mtpService.buildPreview(
                tracks: syncableTracks,
                playlistName: playlistName,
                settings: syncSettings
            )
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
                let result = try await mtpService.sync(
                    tracks: syncableTracks,
                    playlistName: playlistName,
                    settings: syncSettings
                ) { [weak self] progress, message in
                    Task { @MainActor in
                        self?.syncProgress = progress
                        if let message { self?.appendLog(message) }
                    }
                }
                appendLog("MTP sync complete: sent \(result.copiedCount) song(s) to the Garmin.")
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

        if isMTPLibraryMode {
            isManagingDeviceFiles = true
            Task {
                do {
                    let count = try await mtpService.deleteFiles(files) { [weak self] message in
                        Task { @MainActor in
                            self?.appendLog(message)
                        }
                    }
                    selectedDeviceFileIDs.removeAll()
                    appendLog("Deleted \(count) file(s) from Garmin.")
                    browseGarminMusicLibrary()
                } catch {
                    appendLog("Delete failed: \(error.localizedDescription)")
                }
                isManagingDeviceFiles = false
            }
            return
        }

        let urls = files.map(\.url)

        do {
            let count = try contentService.deleteFiles(at: urls)
            selectedDeviceFileIDs.removeAll()
            appendLog("Deleted \(count) file(s) from device folder.")
            refreshDeviceContents()
        } catch {
            appendLog("Delete failed: \(error.localizedDescription)")
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

        if isMTPLibraryMode {
            isManagingDeviceFiles = true
            Task {
                do {
                    let count = try await mtpService.downloadFiles(
                        files,
                        to: destination,
                        fileIDIndex: garminFileIDByName
                    ) { [weak self] message in
                        Task { @MainActor in
                            self?.appendLog(message)
                        }
                    }
                    appendLog("Copied \(count) file(s) from Garmin to \(destination.path).")
                } catch {
                    appendLog("Copy from Garmin failed: \(error.localizedDescription)")
                }
                isManagingDeviceFiles = false
            }
            return
        }

        do {
            let count = try copyDeviceFiles(files, to: destination)
            appendLog("Copied \(count) file(s) from device folder to \(destination.path).")
        } catch {
            appendLog("Copy failed: \(error.localizedDescription)")
        }
    }

    func moveSelectedDeviceFiles() {
        let files = selectedDeviceFiles
        guard !files.isEmpty else { return }

        guard !isMTPLibraryMode else {
            appendLog("Moving files directly on Garmin MTP is not supported by the watch connection. Copy files to the Mac or delete them, then re-sync to the desired playlist/folder.")
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

        do {
            let count = try moveDeviceFiles(files, to: destination)
            selectedDeviceFileIDs.removeAll()
            appendLog("Moved \(count) file(s) to \(destination.path).")
            refreshDeviceContents()
        } catch {
            appendLog("Move failed: \(error.localizedDescription)")
        }
    }

    var isMTPLibraryMode: Bool {
        activeDestination == nil && (
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
            appendLog(deviceBrowseMessage ?? "No Garmin MTP device is connected.")
            return
        }
        guard mtpDependencyStatus.isReady else {
            deviceBrowseMessage = mtpDependencyStatus.message
            appendLog(mtpDependencyStatus.message)
            return
        }

        browseTask?.cancel()
        isBrowsingDevice = true
        deviceBrowseMessage = nil
        appendLog("Loading Garmin music library over MTP…")
        browseTask = Task {
            do {
                let contents = try await mtpService.listDeviceMusicFiles { [weak self] message in
                    Task { @MainActor in
                        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { self?.appendLog(trimmed) }
                    }
                }
                guard !Task.isCancelled else { return }
                deviceFiles = contents.files
                devicePlaylists = contents.playlists
                storageInfo = contents.storageInfo
                garminFileIDByName = contents.fileIDByName
                deviceBrowseMessage = contents.diagnosticMessage
                isMTPLibraryLoaded = true
                if let deviceName = contents.deviceName {
                    connectedMTPDeviceName = deviceName
                }
                updateDuplicateFlags()
                let playlistSummary = contents.playlists.isEmpty
                    ? "no playlists"
                    : "\(contents.playlists.count) playlist(s)"
                appendLog("Garmin library: \(contents.files.count) audio file(s), \(playlistSummary).")
                if let diagnosticMessage = contents.diagnosticMessage {
                    appendLog(diagnosticMessage)
                }
            } catch {
                if !Task.isCancelled {
                    deviceBrowseMessage = error.localizedDescription
                    appendLog("Could not read Garmin library: \(error.localizedDescription)")
                }
            }
            isBrowsingDevice = false
            browseTask = nil
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
