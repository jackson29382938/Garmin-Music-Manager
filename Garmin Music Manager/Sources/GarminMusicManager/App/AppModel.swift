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
    /// Structured send progress (N of M, track name). Nil when idle.
    @Published var transferProgress: TransferProgressSnapshot?
    /// ContentView flips to On Watch when this becomes true.
    @Published var shouldFocusOnWatch = false
    /// ContentView switches to Transfer when true (e.g. after Apple Music import).
    @Published var shouldFocusTransfer = false
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
    /// When true (default), Send opens a preview sheet first.
    @Published var alwaysPreviewBeforeSend: Bool {
        didSet { persistSettingsIfReady() }
    }
    /// Transfer/session performance knobs (listing reuse, MTP keep-alive, batch size, etc.).
    @Published var performanceSettings: PerformanceSettings {
        didSet {
            applyPerformanceSettings()
            persistSettingsIfReady()
        }
    }
    /// Mac library / import / matching preferences.
    @Published var librarySettings: LibrarySettings {
        didSet {
            applyLibrarySettings()
            persistSettingsIfReady()
        }
    }
    /// Conversion quality and cache.
    @Published var conversionSettings: ConversionSettings {
        didSet {
            applyConversionSettings()
            persistSettingsIfReady()
        }
    }
    /// Post-send / device lifecycle preferences.
    @Published var lifecycleSettings: LifecycleSettings {
        didSet {
            applyLifecycleSettings()
            persistSettingsIfReady()
        }
    }

    /// User-facing banner (not the technical transfer log).
    @Published var userNotice: UserNotice?

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
    /// Avoids spamming the transfer log on per-byte progress; log once per item.
    private var lastLoggedProgressItemIndex: Int?

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
        self.alwaysPreviewBeforeSend = settingsStore.alwaysPreviewBeforeSend
        self.performanceSettings = settingsStore.performanceSettings
        self.librarySettings = settingsStore.librarySettings
        self.conversionSettings = settingsStore.conversionSettings
        self.lifecycleSettings = settingsStore.lifecycleSettings
        self.deviceBrowser.browseMode = settingsStore.advancedStorageExplorerEnabled
            ? settingsStore.lastDeviceBrowseMode
            : .musicOnly
        self.deviceBrowser.listingReuseTTL = performanceSettings.listingReuseSeconds
        self.deviceBrowser.sortOrder = librarySettings.defaultDeviceSort
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
        // Apply MTP helper knobs without re-entering didSet side effects.
        applyMTPClientConfiguration(performanceSettings)
        applyLibrarySettings(initial: true)
        applyConversionSettings(initial: true)
        applyLifecycleSettings(initial: true)
        if autoRefresh {
            if let destination = destinationOverride {
                refreshDeviceContents(at: destination)
            }
            Task { refreshDevices() }
            Task { await self.restoreLibraryQueueIfNeeded() }
            let monitor = DeviceConnectMonitor { [weak self] in
                self?.refreshDevices()
            }
            if performanceSettings.autoDetectDevices {
                monitor.start(pollInterval: performanceSettings.usbPollIntervalSeconds, pollUSB: true)
            }
            self.connectMonitor = monitor
        }
    }

    var canRetryFailedTransfers: Bool {
        !isSyncing
            && !lastFailedTrackIDs.isEmpty
            && tracks.contains { lastFailedTrackIDs.contains($0.id) && $0.compatibility.canCopy }
    }

    /// Label for the retry action (failed only vs continue after cancel).
    var retryFailedTransfersTitle: String {
        "Retry / continue send"
    }

    var syncableTracks: [AudioTrack] {
        macLibrarySession.syncableTracks(
            from: tracks,
            skipDuplicates: librarySettings.skipDuplicatesWhenSending
        )
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
        if syncableTracks.isEmpty { return "Select compatible tracks in the Transfer queue first." }
        if !deviceBrowser.isConfigured && activeDestination == nil && !canAttemptMTP {
            return "Connect a Garmin or choose a destination folder."
        }
        if deviceBrowser.browseMode != .musicOnly {
            return "Switch the On Watch browser back to Music."
        }
        if exceedsAvailableStorage {
            return "Selected tracks exceed free space on the watch."
        }
        return nil
    }

    /// Blocks send when free space is known and selection is too large.
    @discardableResult
    func assertStorageAllowsSend() -> Bool {
        switch librarySettings.storageExceedPolicy {
        case .ignore:
            return true
        case .warnOnly:
            if exceedsAvailableStorage {
                presentNotice(
                    .warning,
                    title: "Selection may not fit",
                    message: "Selected tracks may exceed free space on the watch. You can still send."
                )
            }
            return true
        case .blockSend:
            if exceedsAvailableStorage {
                presentNotice(
                    .error,
                    title: "Not enough free space",
                    message: "Selected tracks exceed free space on the watch. Deselect some tracks or free space, then try again."
                )
                return false
            }
            return true
        }
    }

    /// Short help when the queue has blocked tracks.
    var blockedTracksHelp: String? {
        guard !blockedTracks.isEmpty else { return nil }
        let needsConvert = blockedTracks.contains {
            MusicCompatibilityEvaluator.needsConversion(ext: $0.fileExtension, codecHint: $0.codecHint)
        }
        if needsConvert && !syncSettings.convertIncompatibleFormats {
            return "Some tracks need conversion. Enable Convert ALAC/FLAC in Advanced (requires ffmpeg)."
        }
        if needsConvert && syncSettings.convertIncompatibleFormats && !isFFmpegAvailable {
            return "Conversion is on but ffmpeg is not installed (brew install ffmpeg)."
        }
        if needsConvert {
            return "Some tracks still can’t be sent after conversion. Check the list for details."
        }
        return "DRM or cloud-only tracks can’t be sent. Only local, non-DRM files work."
    }

    /// Cached ffmpeg probe (refreshed on demand).
    private var cachedFFmpegAvailable: Bool?
    private var lastDeviceBusyNoticeAt = Date.distantPast

    /// Whether ffmpeg is on PATH (for optional ALAC/FLAC conversion).
    var isFFmpegAvailable: Bool {
        if let cachedFFmpegAvailable { return cachedFFmpegAvailable }
        let available = AudioConverter().isAvailable
        cachedFFmpegAvailable = available
        return available
    }

    /// True when convert is enabled but ffmpeg is missing.
    var needsFFmpegInstall: Bool {
        syncSettings.convertIncompatibleFormats && !isFFmpegAvailable
    }

    /// Re-probe ffmpeg (Settings / Transfer appear).
    func refreshFFmpegAvailability() {
        cachedFFmpegAvailable = AudioConverter().isAvailable
    }

    /// Surfaces a user-facing notice when convert is turned on without ffmpeg.
    func warnIfConversionNeedsFFmpeg() {
        refreshFFmpegAvailability()
        guard needsFFmpegInstall else { return }
        presentNotice(
            .warning,
            title: "ffmpeg not found",
            message: "Convert ALAC/FLAC is on, but ffmpeg is not installed. Install it with Homebrew: brew install ffmpeg.",
            alsoLog: true
        )
    }

    /// Present a banner when a device-busy MTP error is detected.
    func presentDeviceBusyNoticeIfNeeded(from message: String?) {
        if deviceBrowser.isLastErrorDeviceBusy {
            presentDeviceBusyNoticeDebounced()
            return
        }
        guard let message, !message.isEmpty else { return }
        let lower = message.lowercased()
        guard lower.contains("device-busy")
            || lower.contains("device is busy")
            || lower.contains("another app is using the garmin")
            || lower.contains("resource busy")
            || lower.contains("claim_interface") else { return }
        presentDeviceBusyNoticeDebounced()
    }

    private func presentDeviceBusyNoticeDebounced() {
        // Avoid stacking the same banner from browse log + lastError + sync failure.
        if userNotice?.code == .deviceBusy { return }
        let now = Date()
        guard now.timeIntervalSince(lastDeviceBusyNoticeAt) > 2.5 else { return }
        lastDeviceBusyNoticeAt = now
        presentNotice(TransferCompletionNotice.deviceBusy(), alsoLog: false)
    }

    func dismissNotice() {
        userNotice = nil
    }

    func presentNotice(_ notice: UserNotice, alsoLog: Bool = true) {
        userNotice = notice
        if alsoLog {
            if let message = notice.message, !message.isEmpty {
                appendLog("\(notice.title) — \(message)")
            } else {
                appendLog(notice.title)
            }
        }
    }

    func presentNotice(
        _ kind: UserNoticeKind,
        title: String,
        message: String? = nil,
        action: UserNoticeAction? = nil,
        code: UserNoticeCode? = nil,
        alsoLog: Bool = true
    ) {
        presentNotice(
            UserNotice(kind: kind, title: title, message: message, action: action, code: code),
            alsoLog: alsoLog
        )
    }

    /// Runs the banner CTA (View on Watch / Retry failed), then clears the notice.
    func performNoticeAction() {
        guard let action = userNotice?.action else {
            dismissNotice()
            return
        }
        dismissNotice()
        switch action {
        case .showOnWatch:
            shouldFocusOnWatch = true
        case .retryFailed:
            retryFailedTransfers()
        }
    }

    func consumeFocusOnWatch() {
        shouldFocusOnWatch = false
    }

    func consumeFocusTransfer() {
        shouldFocusTransfer = false
    }

    /// Log + user-facing notice for On Watch file operations (delete/upload/move/copy).
    private func handleDeviceOpLog(_ message: String) {
        appendLog(message)
        presentDeviceBusyNoticeIfNeeded(from: message)
        let lower = message.lowercased()
        if lower.contains("failed") || lower.hasPrefix("could not") {
            presentNotice(.error, title: "On Watch operation failed", message: message, alsoLog: false)
            return
        }
        if lower.contains("deleted")
            || lower.contains("uploaded")
            || lower.contains("copied")
            || lower.contains("moved") {
            presentNotice(.success, title: "On Watch updated", message: message, alsoLog: false)
        }
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
            library: librarySettings,
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
            presentNotice(
                .success,
                title: "Added \(result.addedCount) track(s)",
                message: "Review the queue, then tap Send to Watch.",
                alsoLog: false
            )
        } else if let message = result.message {
            appendLog(message)
            presentNotice(.warning, title: "Nothing added", message: message, alsoLog: false)
        }
    }

    func handleDroppedURLs(_ urls: [URL]) {
        Task { await addFiles(urls) }
    }

    func removeTracks(at offsets: IndexSet) {
        tracks = macLibrarySession.removeTracks(at: offsets, filtered: filteredTracks, from: tracks)
    }

    func removeTracks(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        tracks = macLibrarySession.removeTracks(ids: ids, from: tracks)
        lastFailedTrackIDs.subtract(ids)
    }

    /// Ensures the right-clicked track is part of the isSelected set (Finder-style).
    func prepareMacSelectionForContextMenu(trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if tracks[index].isSelected { return }
        for i in tracks.indices {
            tracks[i].isSelected = tracks[i].id == trackID && tracks[i].compatibility.canCopy
        }
    }

    func revealTracksInFinder(ids: Set<UUID>) {
        let urls = tracks.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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
            library: librarySettings,
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
        if librarySettings.autoDeselectDuplicates {
            tracks = macLibrarySession.applyAutoDeselectDuplicates(tracks, enabled: true)
        }
    }

    /// Primary entry for Send to Watch — preview when required, otherwise send immediately.
    func beginSend() {
        startSend(forcePreview: nil)
    }

    /// Menu quick-send: still respects storage/replace preview rules, but skips
    /// the “always preview” preference so power users get one-click when safe.
    func quickSendSelected() {
        startSend(forcePreview: false, respectAlwaysPreviewPreference: false)
    }

    /// Builds and shows the send preview sheet (always).
    func prepareSyncPreview() {
        startSend(forcePreview: true)
    }

    /// Shared send entry for Transfer button, menu, and quick-send.
    /// - Parameters:
    ///   - forcePreview: `true` always sheet; `false` never from preference; `nil` use policy.
    ///   - respectAlwaysPreviewPreference: when false, “Always preview” is ignored (quick-send).
    private func startSend(forcePreview: Bool?, respectAlwaysPreviewPreference: Bool = true) {
        guard !isSyncing, !isManagingDeviceFiles, !isBrowsingDevice else {
            presentNotice(.info, title: "Busy", message: "Wait for the current transfer or device operation to finish.")
            return
        }
        guard !syncableTracks.isEmpty else {
            if tracks.isEmpty {
                presentNotice(
                    .warning,
                    title: "Add music first",
                    message: "Use Apple Music or Files on Transfer, or drag audio onto the page.",
                    code: .nothingToSend
                )
            } else {
                presentNotice(
                    .warning,
                    title: "No compatible tracks selected",
                    message: blockedTracksHelp ?? "Open Edit selection and choose ready tracks.",
                    code: .nothingToSend
                )
            }
            return
        }
        guard destinationIsReady else {
            presentNotice(
                .warning,
                title: "Connect your Garmin",
                message: connectedUSBDevices.isEmpty
                    ? "Plug in with a data USB cable, unlock the watch, then Refresh."
                    : mtpDependencyStatus.message
            )
            return
        }

        do {
            let preview = try syncSession.buildPreview(
                tracks: syncableTracks,
                playlistName: playlistName,
                settings: syncSettings,
                performance: performanceSettings,
                activeDestination: activeDestination,
                deviceFiles: deviceBrowser.files,
                mtpReady: mtpDependencyStatus.isReady
            )
            syncPreview = preview

            // forcePreview true → always sheet; false/nil → policy (quick-send ignores “always preview”).
            let alwaysFromSettings = respectAlwaysPreviewPreference && alwaysPreviewBeforeSend
            let showPreview = (forcePreview == true) || SendPreviewPolicy.shouldShowPreview(
                alwaysPreview: forcePreview == true ? true : alwaysFromSettings,
                exceedsAvailableStorage: exceedsAvailableStorage,
                preview: preview
            )

            if showPreview {
                showSyncPreview = true
            } else {
                guard assertStorageAllowsSend() else { return }
                Task { await sync() }
            }
        } catch let error as SyncSessionError {
            switch error {
            case .mtpNotReady:
                presentNotice(
                    .error,
                    title: "MTP not ready",
                    message: mtpDependencyStatus.message,
                    code: .mtpNotReady
                )
            }
        } catch {
            presentNotice(.error, title: "Could not prepare send", message: error.localizedDescription)
        }
    }

    func confirmSync() {
        guard assertStorageAllowsSend() else { return }
        showSyncPreview = false
        Task { await sync() }
    }

    func cancelSync() {
        // Notice comes from session onCancelled / MTP wasCancelled completion.
        syncSession.cancel()
        appendLog("Sync cancelled.")
        isSyncing = false
        transferProgress = nil
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
            presentNotice(.warning, title: "Nothing to send", message: "Add compatible selected files first.")
            return
        }
        guard assertStorageAllowsSend() else { return }

        isSyncing = true
        syncProgress = 0
        transferProgress = .phase(0, "Starting…")
        lastLoggedProgressItemIndex = nil
        dismissNotice()
        persistSettingsIfReady(force: true)

        defer {
            isSyncing = false
            syncProgress = 1
            transferProgress = nil
            lastLoggedProgressItemIndex = nil
        }

        await syncSession.run(
            tracks: syncableTracks,
            playlistName: playlistName,
            settings: syncSettings,
            performance: performanceSettings,
            conversion: conversionSettings,
            refreshAfterSend: lifecycleSettings.refreshDeviceAfterSend,
            activeDestination: activeDestination,
            mtpReady: mtpDependencyStatus.isReady,
            mtpNotReadyMessage: mtpDependencyStatus.message,
            deviceBrowser: deviceBrowser,
            configureMTP: { [weak self] in self?.configureMTPBrowser() },
            onProgress: { [weak self] snapshot in
                self?.applyTransferProgressSnapshot(snapshot)
            },
            onLog: { [weak self] message in
                self?.appendLog(message)
                self?.presentDeviceBusyNoticeIfNeeded(from: message)
            },
            onMountedComplete: { [weak self] result in
                guard let self else { return }
                self.lastFailedTrackIDs = []
                self.refreshDeviceContents(at: result.targetFolder)
                self.presentNotice(TransferCompletionNotice.forMounted(result), alsoLog: false)
            },
            onMTPComplete: { [weak self] result in
                guard let self else { return }
                // Include remaining (not attempted) so Cancel → Retry continues the rest.
                self.lastFailedTrackIDs = Set(result.retryTrackIDs)
                self.applyPostMTPTransferUI(forceLibraryRefresh: false)
                self.presentMTPCompletionNotice(result)
            },
            onCancelled: { [weak self] in
                // Only used when the task throws CancellationError before MTP result.
                // If userNotice already set by MTP completion, leave it.
                guard let self, self.userNotice == nil else { return }
                self.presentNotice(TransferCompletionNotice.cancelled(), alsoLog: false)
            },
            onFailed: { [weak self] error in
                guard let self else { return }
                self.presentDeviceBusyNoticeIfNeeded(from: error.localizedDescription)
                if self.userNotice?.code == .deviceBusy {
                    return
                }
                self.presentNotice(TransferCompletionNotice.failed(error.localizedDescription), alsoLog: false)
            }
        )
    }

    /// Updates live progress UI and logs once per file start (not per-byte).
    private func applyTransferProgressSnapshot(_ snapshot: TransferProgressSnapshot) {
        syncProgress = snapshot.fraction
        transferProgress = snapshot
        guard let itemIndex = snapshot.itemIndex else { return }
        if lastLoggedProgressItemIndex == itemIndex { return }
        lastLoggedProgressItemIndex = itemIndex
        if let label = snapshot.itemLabel {
            appendLog("Uploading \(label)")
        } else if let message = snapshot.message, !message.isEmpty {
            appendLog(message)
        }
    }

    /// Re-selects only tracks that failed the last MTP transfer and starts a new send.
    func retryFailedTransfers() {
        guard canRetryFailedTransfers else {
            presentNotice(.info, title: "Nothing to retry", message: "There are no failed tracks left in the queue.")
            return
        }
        tracks = macLibrarySession.selectOnly(ids: lastFailedTrackIDs, in: tracks)
        let count = tracks.filter { $0.isSelected }.count
        appendLog("Retrying \(count) failed track(s)…")
        if alwaysPreviewBeforeSend {
            prepareSyncPreview()
        } else {
            Task { await sync() }
        }
    }

    func installMTPDependencies() {
        guard !isInstallingMTPDependencies else { return }
        isInstallingMTPDependencies = true
        presentNotice(.info, title: "Installing MTP support…", message: "Homebrew/libmtp may be installed if needed.")
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
                if mtpDependencyStatus.isReady {
                    presentNotice(.success, title: "MTP ready", message: mtpDependencyStatus.message, alsoLog: false)
                } else {
                    presentNotice(.warning, title: "MTP still not ready", message: mtpDependencyStatus.message, alsoLog: false)
                }
                refreshDevices()
            } catch {
                presentNotice(.error, title: "MTP install failed", message: error.localizedDescription)
            }
        }
    }

    private func presentMTPCompletionNotice(_ result: MTPSyncResult) {
        let canRetry = !result.retryTrackIDs.isEmpty
            && tracks.contains { result.retryTrackIDs.contains($0.id) && $0.compatibility.canCopy }
        presentNotice(TransferCompletionNotice.forMTP(result, canRetry: canRetry), alsoLog: false)
    }

    func deleteSelectedDeviceFiles() {
        deviceSession.deleteSelected(
            deviceBrowser: deviceBrowser,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            onFinished: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.handleDeviceOpLog(message) }
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
            log: { [weak self] message in self?.handleDeviceOpLog(message) }
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
            log: { [weak self] message in self?.handleDeviceOpLog(message) }
        )
    }

    func confirmDeleteOriginalsAfterMTPMove() {
        deviceSession.confirmDeleteOriginalsAfterMTPMove(
            deviceBrowser: deviceBrowser,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            setShowConfirmation: { [weak self] value in self?.showMTPMoveDeleteConfirmation = value },
            onFinished: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.handleDeviceOpLog(message) }
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
            log: { [weak self] message in
                self?.appendLog(message)
                self?.presentDeviceBusyNoticeIfNeeded(from: message)
                self?.presentDeviceBusyNoticeIfNeeded(from: self?.deviceBrowser.lastError)
            }
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
            log: { [weak self] message in self?.handleDeviceOpLog(message) }
        )
    }

    func uploadFilesToDevice(_ urls: [URL]) {
        guard prepareDeviceBrowserForUpload() else { return }
        deviceSession.uploadFiles(
            urls,
            deviceBrowser: deviceBrowser,
            setManaging: { [weak self] value in self?.isManagingDeviceFiles = value },
            onFinished: { [weak self] in self?.updateDuplicateFlags() },
            log: { [weak self] message in self?.handleDeviceOpLog(message) }
        )
    }

    /// Menu quick-send: same engine as Send to Watch; skips “always preview” preference
    /// but still shows a preview when free space is low or files would be replaced.
    func uploadSelectedTracksToDevice() {
        guard canUploadSelectedTracksToDevice || canSync else {
            if let reason = uploadDisabledReason {
                presentNotice(.warning, title: "Can’t send yet", message: reason)
            } else {
                presentNotice(.warning, title: "Nothing to send", message: "Select compatible tracks in the Transfer queue first.")
            }
            return
        }
        guard prepareDeviceBrowserForUpload() else {
            presentNotice(.warning, title: "Destination not ready", message: "Connect a Garmin or choose a music folder.")
            return
        }
        appendLog("Quick-send selected tracks…")
        quickSendSelected()
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
        guard !plan.urls.isEmpty else {
            presentNotice(
                .warning,
                title: "Nothing to import",
                message: plan.skipped > 0
                    ? "No local, non-DRM tracks (\(plan.skipped) cloud/DRM skipped)."
                    : "No local, non-DRM tracks in this selection."
            )
            return
        }
        if plan.closeBrowser {
            showAppleMusicBrowser = false
        }
        Task {
            await addFiles(plan.urls)
            shouldFocusTransfer = true
            var message = "Added \(plan.urls.count) track(s) to the Transfer queue."
            if plan.skipped > 0 {
                message += " Skipped \(plan.skipped) cloud-only/DRM."
            }
            message += " Tap Send to Watch when ready."
            presentNotice(.success, title: "Added to queue", message: message, alsoLog: false)
        }
    }

    func prepareAppleMusicPlaylistForSync(_ playlistID: String) {
        Task { await prepareAppleMusicPlaylistForSyncNow(playlistID) }
    }

    func prepareAppleMusicPlaylistForSyncNow(_ playlistID: String) async {
        let plan = macLibrarySession.planAppleMusicPlaylist(playlistID: playlistID, musicLibrary: musicLibrary)
        for line in plan.logMessages {
            appendLog(line)
        }
        guard !plan.urls.isEmpty else {
            presentNotice(
                .warning,
                title: "Nothing to import",
                message: plan.skipped > 0
                    ? "No local files in this playlist (\(plan.skipped) cloud/DRM skipped)."
                    : "No local, non-DRM tracks in this playlist."
            )
            return
        }
        if let name = plan.playlistName {
            playlistName = name
        }
        if plan.closeBrowser {
            showAppleMusicBrowser = false
        }
        if plan.replaceQueue {
            await replaceTracks(with: plan.urls)
            shouldFocusTransfer = true
            var message = "“\(playlistName)” — \(tracks.count) track(s)."
            if plan.skipped > 0 {
                message += " Skipped \(plan.skipped) cloud-only/DRM."
            }
            message += " Tap Send to Watch."
            presentNotice(.success, title: "Playlist ready", message: message, alsoLog: false)
        } else {
            await addFiles(plan.urls)
            shouldFocusTransfer = true
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
        transferProgress = nil
        shouldFocusOnWatch = false
        shouldFocusTransfer = false
        showSyncPreview = false
        syncPreview = nil
        userNotice = nil
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
        alwaysPreviewBeforeSend = settingsStore.alwaysPreviewBeforeSend
        performanceSettings = settingsStore.performanceSettings
        settingsReady = true
        applyPerformanceSettings()
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

    /// Restore Performance knobs to Balanced shipping defaults (does not reset sync policies).
    func restorePerformanceDefaults() {
        performanceSettings = .template(for: .balanced)
    }

    /// Apply a named performance preset (ignores `.custom`).
    func applyPerformancePreset(_ preset: PerformancePreset) {
        guard preset != .custom else { return }
        performanceSettings = .template(for: preset)
    }

    private func applyPerformanceSettings() {
        let settings = performanceSettings.clamped
        deviceBrowser.listingReuseTTL = settings.listingReuseSeconds
        applyMTPClientConfiguration(settings)
        connectMonitor?.reconfigure(
            enabled: settings.autoDetectDevices,
            pollInterval: settings.usbPollIntervalSeconds
        )
        // Refresh MTP backend flags when already configured for MTP.
        if deviceBrowser.backendKind == .mtp {
            configureMTPBrowser()
        }
    }

    private func applyMTPClientConfiguration(_ settings: PerformanceSettings) {
        let s = settings.clamped
        let updatePlaylist = lifecycleSettings.playlistWriteStrategy == .updateIfExists
        MTPHelperClient.configure(
            uploadChunkSize: s.uploadBatchSize,
            idleTimeout: s.mtpSessionKeepAliveSeconds,
            retryAttempts: s.mtpRetryAttempts,
            retryBackoff: s.mtpRetryBackoffSeconds,
            timeoutScale: s.operationTimeoutScale,
            verifyUploads: s.verifyUploads,
            updateExistingPlaylist: updatePlaylist
        )
    }

    private func applyLibrarySettings(initial: Bool = false) {
        let lib = librarySettings.clamped
        MusicCompatibilityEvaluator.largeFileWarningBytes = lib.largeFileWarningBytes
        TrackMatching.matchMode = lib.duplicateMatchMode
        TrackMatching.durationToleranceSeconds = lib.durationMatchToleranceSeconds
        if !initial {
            deviceBrowser.sortOrder = lib.defaultDeviceSort
            if lib.autoDeselectDuplicates {
                tracks = macLibrarySession.applyAutoDeselectDuplicates(tracks, enabled: true)
            }
        } else {
            deviceBrowser.sortOrder = lib.defaultDeviceSort
        }
    }

    private func applyConversionSettings(initial: Bool = false) {
        let conv = conversionSettings.clamped
        AudioConverter.customFFmpegPath = conv.resolvedFFmpegPath
        MusicCompatibilityEvaluator.convertWAV = conv.convertWAV
    }

    private func applyLifecycleSettings(initial: Bool = false) {
        let life = lifecycleSettings.clamped
        MTPSyncPlanner.remoteMusicRoot = life.remoteMusicRoot
        if !initial {
            applyMTPClientConfiguration(performanceSettings)
        }
    }

    private func handleSendFinished(success: Bool, detail: UserNotice?) {
        if let detail {
            presentNotice(detail, alsoLog: false)
        }
        if success, conversionSettings.clearCacheAfterSuccessfulSend {
            try? AudioConverter.clearTemporaryConversions()
        }
        if lifecycleSettings.releaseHelperAfterSend {
            Task { await MTPHelperClient.shutdownSharedHelper() }
        }
        if lifecycleSettings.notifyOnSendComplete {
            postSendNotification(success: success)
        }
    }

    private func postSendNotification(success: Bool) {
        // Prefer in-app notice; system notifications require UserNotifications authorization.
        if userNotice == nil {
            presentNotice(
                success ? .success : .warning,
                title: success ? "Send complete" : "Send finished with issues",
                message: success
                    ? "Tracks were sent to your Garmin."
                    : "Check the transfer log for details.",
                alsoLog: false
            )
        }
        NSSound.beep()
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
        settingsStore.alwaysPreviewBeforeSend = alwaysPreviewBeforeSend
        settingsStore.performanceSettings = performanceSettings
        settingsStore.librarySettings = librarySettings
        settingsStore.conversionSettings = conversionSettings
        settingsStore.lifecycleSettings = lifecycleSettings
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
            library: librarySettings,
            setScanning: { [weak self] value in self?.isScanning = value }
        )
        tracks = result.tracks
        updateDuplicateFlags()
    }

    private func appendLog(_ message: String) {
        transferLogStore.append(message)
        transferLog = transferLogStore.lines
    }

    /// Recent log lines for the Transfer activity panel (newest last).
    var recentTransferLogLines: [String] {
        Array(transferLog.suffix(40))
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
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled,
            includePlaylistContents: performanceSettings.includePlaylistContentsWhenBrowsing
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
