import Foundation
import GarminMusicCore

@MainActor
final class DeviceLibraryCoordinator {
    func updateDuplicateFlags(
        tracks: [AudioTrack],
        deviceBrowser: DeviceBrowserStore,
        activeDestination: URL?,
        isMTPLibraryMode: Bool,
        playlistName: String,
        syncSettings: SyncSettings,
        contentService: DeviceContentService
    ) -> [AudioTrack] {
        if isMTPLibraryMode || deviceBrowser.backendKind == .mtp {
            var fingerprintIndex = Set<String>()
            for file in deviceBrowser.files where file.type == .audio {
                for key in TrackMatching.deviceFingerprintKeys(for: file) {
                    fingerprintIndex.insert(key)
                }
            }
            let pathIndex = Set(deviceBrowser.files.map { MTPSyncPlanner.normalizePath($0.path) })
            return tracks.map { track in
                var updated = track
                let remotePath = MTPSyncPlanner.remotePath(
                    for: track,
                    playlistName: playlistName,
                    settings: syncSettings
                )
                let normalizedRemotePath = MTPSyncPlanner.normalizePath(remotePath)
                let fingerprints = TrackMatching.trackFingerprintKeys(for: track)
                updated.isDuplicateOnDevice = fingerprints.contains(where: { fingerprintIndex.contains($0) })
                    || pathIndex.contains(normalizedRemotePath)
                return updated
            }
        }
        guard let destination = activeDestination else { return tracks }
        return contentService.markDuplicates(tracks: tracks, destination: destination, playlistName: playlistName)
    }

    func configureMountedBrowser(
        deviceBrowser: DeviceBrowserStore,
        destination: URL,
        displayName: String,
        advancedStorageExplorerEnabled: Bool
    ) {
        deviceBrowser.configure(backend: MountedFolderDeviceFileSystem(rootURL: destination, displayName: displayName))
        if deviceBrowser.browseMode == .advancedStorage && !advancedStorageExplorerEnabled {
            deviceBrowser.setBrowseMode(.musicOnly, advancedEnabled: false)
        }
    }

    func configureMTPBrowser(
        deviceBrowser: DeviceBrowserStore,
        connectedUSBDevices: [GarminUSBDevice],
        connectedMTPDeviceName: String?,
        advancedStorageExplorerEnabled: Bool,
        includePlaylistContents: Bool = false
    ) {
        let device = connectedUSBDevices.first
        let deviceName = connectedMTPDeviceName ?? device?.displayName ?? "Garmin watch"
        let deviceID = device?.dedupeKey ?? deviceName
        let fs = MTPDeviceFileSystem(deviceID: deviceID, displayName: deviceName)
        fs.includePlaylistContents = includePlaylistContents
        deviceBrowser.configure(backend: fs)
        if deviceBrowser.browseMode == .advancedStorage && !advancedStorageExplorerEnabled {
            deviceBrowser.setBrowseMode(.musicOnly, advancedEnabled: false)
        }
    }
}
