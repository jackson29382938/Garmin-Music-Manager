import AppKit
import Foundation
import GarminMusicCore
import UniformTypeIdentifiers

/// Owns Garmin device browse / upload / delete / move task lifecycle.
/// UI-facing flags (`isBrowsingDevice`, sheets, etc.) stay on `AppModel`.
@MainActor
final class DeviceSessionController {
    private let deviceLibraryCoordinator = DeviceLibraryCoordinator()
    private let deviceOperationsCoordinator = DeviceOperationsCoordinator()
    private let contentService = DeviceContentService()
    private var browseTask: Task<Void, Never>?
    private var deviceFileTask: Task<Void, Never>?
    private var pendingMTPMoveOriginals: [DeviceFile] = []

    var hasPendingMTPMoveOriginals: Bool { !pendingMTPMoveOriginals.isEmpty }

    func cancelInFlight() {
        browseTask?.cancel()
        browseTask = nil
        deviceFileTask?.cancel()
        deviceFileTask = nil
        Task { await MTPHelperClient.cancelInFlightHelper() }
    }

    func reset() {
        cancelInFlight()
        pendingMTPMoveOriginals = []
    }

    // MARK: - Configuration

    func configureMountedBrowser(
        deviceBrowser: DeviceBrowserStore,
        destination: URL,
        displayName: String,
        advancedStorageExplorerEnabled: Bool
    ) {
        deviceLibraryCoordinator.configureMountedBrowser(
            deviceBrowser: deviceBrowser,
            destination: destination,
            displayName: displayName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
        )
    }

    func configureMTPBrowser(
        deviceBrowser: DeviceBrowserStore,
        connectedUSBDevices: [GarminUSBDevice],
        connectedMTPDeviceName: String?,
        advancedStorageExplorerEnabled: Bool
    ) {
        deviceLibraryCoordinator.configureMTPBrowser(
            deviceBrowser: deviceBrowser,
            connectedUSBDevices: connectedUSBDevices,
            connectedMTPDeviceName: connectedMTPDeviceName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
        )
    }

    func prepareDeviceBrowserForUpload(
        deviceBrowser: DeviceBrowserStore,
        activeDestination: URL?,
        selectedDeviceName: String?,
        hasMTPDestination: Bool,
        mtpDependencyStatus: MTPDependencyStatus,
        connectedUSBDevices: [GarminUSBDevice],
        connectedMTPDeviceName: String?,
        advancedStorageExplorerEnabled: Bool,
        log: (String) -> Void
    ) -> Bool {
        deviceOperationsCoordinator.prepareDeviceBrowserForUpload(
            deviceBrowser: deviceBrowser,
            activeDestination: activeDestination,
            selectedDeviceName: selectedDeviceName,
            hasMTPDestination: hasMTPDestination,
            mtpDependencyStatus: mtpDependencyStatus,
            connectedUSBDevices: connectedUSBDevices,
            connectedMTPDeviceName: connectedMTPDeviceName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled,
            log: log
        )
    }

    func updateDuplicateFlags(
        tracks: [AudioTrack],
        deviceBrowser: DeviceBrowserStore,
        activeDestination: URL?,
        isMTPLibraryMode: Bool,
        playlistName: String,
        syncSettings: SyncSettings
    ) -> [AudioTrack] {
        deviceLibraryCoordinator.updateDuplicateFlags(
            tracks: tracks,
            deviceBrowser: deviceBrowser,
            activeDestination: activeDestination,
            isMTPLibraryMode: isMTPLibraryMode,
            playlistName: playlistName,
            syncSettings: syncSettings,
            contentService: contentService
        )
    }

    func defaultMoveTargetPath(playlistName: String) -> String {
        deviceOperationsCoordinator.defaultMoveTargetPath(playlistName: playlistName)
    }

    func normalizedMoveTargetPath(_ path: String, playlistName: String) -> String {
        deviceOperationsCoordinator.normalizedMoveTargetPath(path, playlistName: playlistName)
    }

    func shouldConfirmDelete(
        files: [DeviceFile],
        browseMode: DeviceBrowseMode,
        mode: DestructiveConfirmationMode
    ) -> Bool {
        deviceOperationsCoordinator.shouldConfirmDelete(
            files: files,
            browseMode: browseMode,
            mode: mode
        )
    }

    // MARK: - Browse

    func refreshMountedContents(
        deviceBrowser: DeviceBrowserStore,
        destination: URL,
        displayName: String,
        advancedStorageExplorerEnabled: Bool,
        onFinished: @escaping () -> Void
    ) {
        configureMountedBrowser(
            deviceBrowser: deviceBrowser,
            destination: destination,
            displayName: displayName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
        )
        browseTask?.cancel()
        browseTask = Task {
            defer { browseTask = nil }
            await deviceBrowser.refresh(force: true)
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }

    func browseMTPLibrary(
        deviceBrowser: DeviceBrowserStore,
        force: Bool,
        hasMTPDestination: Bool,
        mtpReady: Bool,
        mtpMessage: String,
        connectedUSBDevices: [GarminUSBDevice],
        connectedMTPDeviceName: String?,
        advancedStorageExplorerEnabled: Bool,
        isBrowsingDevice: Bool,
        isManagingDeviceFiles: Bool,
        setBrowsing: @escaping (Bool) -> Void,
        setConnectedMTPDeviceName: @escaping (String?) -> Void,
        onDuplicates: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        guard !isBrowsingDevice, !isManagingDeviceFiles else { return }
        guard hasMTPDestination else {
            let message = "No Garmin MTP device is connected. Connect the watch over USB and refresh."
            deviceBrowser.statusMessage = message
            log(message)
            return
        }
        guard mtpReady else {
            deviceBrowser.statusMessage = mtpMessage
            log(mtpMessage)
            return
        }

        browseTask?.cancel()
        configureMTPBrowser(
            deviceBrowser: deviceBrowser,
            connectedUSBDevices: connectedUSBDevices,
            connectedMTPDeviceName: connectedMTPDeviceName,
            advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
        )
        setBrowsing(true)
        if force {
            log("Loading Garmin music library over MTP…")
        }
        browseTask = Task {
            defer {
                setBrowsing(false)
                browseTask = nil
            }
            await deviceBrowser.refresh(force: force)
            guard !Task.isCancelled else { return }
            applyPostTransferUI(
                deviceBrowser: deviceBrowser,
                logSummary: force,
                setConnectedMTPDeviceName: setConnectedMTPDeviceName,
                onDuplicates: onDuplicates,
                log: log
            )
        }
    }

    func applyPostTransferUI(
        deviceBrowser: DeviceBrowserStore,
        logSummary: Bool,
        setConnectedMTPDeviceName: @escaping (String?) -> Void,
        onDuplicates: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        if let deviceName = deviceBrowser.deviceName {
            setConnectedMTPDeviceName(deviceName)
        }
        onDuplicates()
        guard logSummary else { return }
        let playlistCount = deviceBrowser.collections.filter { $0.kind == .playlist }.count
        let playlistSummary = playlistCount == 0 ? "no playlists" : "\(playlistCount) playlist(s)"
        log("Garmin library: \(deviceBrowser.files.filter { $0.type == .audio }.count) audio file(s), \(playlistSummary).")
        if let error = deviceBrowser.lastError {
            log("Could not read Garmin library: \(error)")
        } else if let diagnosticMessage = deviceBrowser.statusMessage {
            log(diagnosticMessage)
        }
    }

    func switchBrowseMode(
        deviceBrowser: DeviceBrowserStore,
        mode: DeviceBrowseMode,
        advancedEnabled: Bool,
        onBrowseModePersisted: (DeviceBrowseMode) -> Void,
        onFinished: @escaping () -> Void
    ) {
        deviceBrowser.setBrowseMode(mode, advancedEnabled: advancedEnabled)
        onBrowseModePersisted(deviceBrowser.browseMode)
        browseTask?.cancel()
        browseTask = Task {
            defer { browseTask = nil }
            await deviceBrowser.refresh(force: false)
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }

    // MARK: - Destructive / transfer ops

    func deleteSelected(
        deviceBrowser: DeviceBrowserStore,
        setManaging: @escaping (Bool) -> Void,
        onFinished: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        let files = deviceBrowser.selectedFiles
        guard !files.isEmpty else { return }

        setManaging(true)
        deviceFileTask = Task {
            defer {
                setManaging(false)
                deviceFileTask = nil
            }
            let result = await deviceBrowser.deleteSelected()
            if let result {
                log(result.message ?? "Deleted \(result.completedCount) file(s).")
            } else if let error = deviceBrowser.lastError {
                log("Delete failed: \(error)")
            }
            onFinished()
        }
    }

    func copySelectedToMac(
        deviceBrowser: DeviceBrowserStore,
        setManaging: @escaping (Bool) -> Void,
        log: @escaping (String) -> Void
    ) {
        let files = deviceBrowser.selectedFiles
        guard !files.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose where to copy Garmin files"
        panel.message = "Select a folder on this Mac."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        setManaging(true)
        deviceFileTask = Task {
            defer {
                setManaging(false)
                deviceFileTask = nil
            }
            let result = await deviceBrowser.copySelected(to: destination)
            if let result {
                log(result.message ?? "Copied \(result.completedCount) file(s) to \(destination.path).")
            } else if let error = deviceBrowser.lastError {
                log("Copy failed: \(error)")
            }
        }
    }

    /// Returns `true` if originals were staged for delete confirmation after MTP copy-move.
    @discardableResult
    func moveSelectedWithinGarmin(
        deviceBrowser: DeviceBrowserStore,
        path: String,
        playlistName: String,
        activeDestination: URL?,
        setManaging: @escaping (Bool) -> Void,
        setShowMTPMoveDeleteConfirmation: @escaping (Bool) -> Void,
        onFinished: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) -> String {
        let files = deviceBrowser.selectedFiles.filter { $0.type != .folder }
        let defaultPath = defaultMoveTargetPath(playlistName: playlistName)
        let target = GarminFolderTarget(
            normalizedMoveTargetPath(path, playlistName: playlistName),
            defaultingTo: defaultPath
        )
        guard !files.isEmpty else { return target.storagePath }

        setManaging(true)
        deviceFileTask = Task {
            defer {
                setManaging(false)
                deviceFileTask = nil
            }
            let result: DeviceFileOperationResult?
            if deviceBrowser.backendKind == .mtp {
                result = await deviceBrowser.copySelectedWithinMTP(to: target)
                if let result, result.completedCount > 0 {
                    let failedNames = Set(result.failedItems)
                    pendingMTPMoveOriginals = files.filter { !failedNames.contains($0.name) }
                    setShowMTPMoveDeleteConfirmation(!pendingMTPMoveOriginals.isEmpty)
                }
            } else if let activeDestination {
                result = await deviceBrowser.moveSelected(to: target.destinationURL(relativeTo: activeDestination))
            } else {
                log("Choose or connect a Garmin destination before moving files.")
                result = nil
            }

            if let result {
                log(result.message ?? "Moved \(result.completedCount) file(s) within Garmin.")
            } else if let error = deviceBrowser.lastError {
                log("Move failed: \(error)")
            }
            onFinished()
        }
        return target.storagePath
    }

    func confirmDeleteOriginalsAfterMTPMove(
        deviceBrowser: DeviceBrowserStore,
        setManaging: @escaping (Bool) -> Void,
        setShowConfirmation: @escaping (Bool) -> Void,
        onFinished: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        let originals = pendingMTPMoveOriginals
        pendingMTPMoveOriginals = []
        setShowConfirmation(false)
        guard !originals.isEmpty else { return }

        setManaging(true)
        deviceFileTask = Task {
            defer {
                setManaging(false)
                deviceFileTask = nil
            }
            let result = await deviceBrowser.delete(originals)
            if let result {
                log(result.message ?? "Deleted \(result.completedCount) original file(s) after MTP move.")
            } else if let error = deviceBrowser.lastError {
                log("Could not delete original files after MTP move: \(error)")
            }
            onFinished()
        }
    }

    func cancelDeleteOriginalsAfterMTPMove(
        setShowConfirmation: @escaping (Bool) -> Void,
        log: @escaping (String) -> Void
    ) {
        pendingMTPMoveOriginals = []
        setShowConfirmation(false)
        log("Kept original files after copying within Garmin.")
    }

    func chooseAndUploadFiles(
        deviceBrowser: DeviceBrowserStore,
        setManaging: @escaping (Bool) -> Void,
        onFinished: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        guard deviceBrowser.isConfigured else {
            log("Choose or connect a Garmin destination first.")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose music files to add to Garmin"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MusicScanner.supportedPickerTypes

        guard panel.runModal() == .OK else { return }
        uploadFiles(
            panel.urls,
            deviceBrowser: deviceBrowser,
            setManaging: setManaging,
            onFinished: onFinished,
            log: log
        )
    }

    func uploadFiles(
        _ urls: [URL],
        deviceBrowser: DeviceBrowserStore,
        setManaging: @escaping (Bool) -> Void,
        onFinished: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        let audioURLs = deviceOperationsCoordinator.expandAudioURLs(urls)
        guard !audioURLs.isEmpty else {
            log("No compatible music files were selected.")
            return
        }
        guard deviceBrowser.browseMode == .musicOnly else {
            log("Switch the Garmin browser back to Music before adding tracks.")
            return
        }

        setManaging(true)
        let uploadFiles = deviceOperationsCoordinator.makeUploadFiles(
            urls: audioURLs,
            backendKind: deviceBrowser.backendKind
        )
        deviceFileTask = Task {
            defer {
                setManaging(false)
                deviceFileTask = nil
            }
            let result = await deviceBrowser.upload(uploadFiles)
            if let result {
                log(result.message ?? "Uploaded \(result.completedCount) file(s) to Garmin.")
            } else if let error = deviceBrowser.lastError {
                log("Upload failed: \(error)")
            }
            onFinished()
        }
    }

    // “Send Selected to Garmin” shares `SyncSessionController.run` with Sync Playlist
    // (see `AppModel.uploadSelectedTracksToDevice`) so plan / convert / playlist logic
    // cannot drift between the two entry points.
}
