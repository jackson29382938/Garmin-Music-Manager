import Foundation
import GarminMusicCore

/// Device browse / upload / delete / move workflows extracted from `AppModel`.
@MainActor
final class DeviceOperationsCoordinator {
    private let scanner = MusicScanner()
    private let syncCoordinator = SyncCoordinator()
    private let deviceLibraryCoordinator = DeviceLibraryCoordinator()

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
        if deviceBrowser.isConfigured {
            return true
        }
        if let destination = activeDestination {
            deviceLibraryCoordinator.configureMountedBrowser(
                deviceBrowser: deviceBrowser,
                destination: destination,
                displayName: selectedDeviceName ?? destination.lastPathComponent,
                advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
            )
            return true
        }
        if hasMTPDestination {
            guard mtpDependencyStatus.isReady else {
                log(mtpDependencyStatus.message)
                return false
            }
            deviceLibraryCoordinator.configureMTPBrowser(
                deviceBrowser: deviceBrowser,
                connectedUSBDevices: connectedUSBDevices,
                connectedMTPDeviceName: connectedMTPDeviceName,
                advancedStorageExplorerEnabled: advancedStorageExplorerEnabled
            )
            return true
        }
        log("Connect a Garmin or choose a destination folder before sending music.")
        return false
    }

    func makeUploadFiles(urls: [URL], backendKind: DeviceBackendKind?) -> [DeviceUploadFile] {
        urls.map { url in
            let remotePath: String
            if backendKind == .mtp {
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

    func makeUploadFiles(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        backendKind: DeviceBackendKind?
    ) -> [DeviceUploadFile] {
        let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
        return tracks.map { track in
            let relativePath = MTPSyncPlanner.playlistRelativePath(
                for: track,
                playlistName: playlistName,
                settings: settings
            )
            let remotePath = backendKind == .mtp ? "Music/\(relativePath)" : relativePath
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

    func expandAudioURLs(_ urls: [URL]) -> [URL] {
        var audioURLs: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                audioURLs.append(contentsOf: scanner.findAudioFiles(in: url))
            } else if MusicScanner.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                audioURLs.append(url)
            }
        }
        return audioURLs
    }

    func shouldConfirmDelete(
        files: [DeviceFile],
        browseMode: DeviceBrowseMode,
        mode: DestructiveConfirmationMode
    ) -> Bool {
        if browseMode == .advancedStorage, files.contains(where: { !$0.isInMusicArea }) {
            return true
        }
        switch mode {
        case .always:
            return true
        case .batchesOnly:
            return files.count > 1
        case .never:
            return false
        }
    }

    func defaultMoveTargetPath(playlistName: String) -> String {
        GarminFolderTarget.defaultMovePath(playlistName: playlistName)
    }

    func normalizedMoveTargetPath(_ path: String, playlistName: String) -> String {
        let defaultPath = defaultMoveTargetPath(playlistName: playlistName)
        let normalized = GarminFolderTarget.normalizedStoragePath(path, defaultingTo: defaultPath)
        if normalized.localizedCaseInsensitiveCompare("Music") == .orderedSame
            || normalized.lowercased().hasPrefix("music/")
            || normalized.contains("/") {
            return normalized
        }
        return "Music/\(normalized)"
    }
}
