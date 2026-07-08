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
            let nameIndex = Set(deviceBrowser.files.map { "\($0.name.lowercased())|\($0.size)" })
            let pathIndex = Set(deviceBrowser.files.map { MTPSyncPlanner.normalizePath($0.path) })
            return tracks.map { track in
                var updated = track
                let key = "\(FileNameSanitizer.safeFileName(for: track).lowercased())|\(track.byteCount)"
                let altKey = "\(track.fileName.lowercased())|\(track.byteCount)"
                let remotePath = MTPSyncPlanner.remotePath(
                    for: track,
                    playlistName: playlistName,
                    settings: syncSettings
                )
                let normalizedRemotePath = MTPSyncPlanner.normalizePath(remotePath)
                updated.isDuplicateOnDevice = nameIndex.contains(key)
                    || nameIndex.contains(altKey)
                    || pathIndex.contains(normalizedRemotePath)
                return updated
            }
        }
        guard let destination = activeDestination else { return tracks }
        return contentService.markDuplicates(tracks: tracks, destination: destination, playlistName: playlistName)
    }

    func syncLegacyDeviceSnapshot(from deviceBrowser: DeviceBrowserStore, activeDestination: URL?) -> LegacyDeviceSnapshot {
        let deviceFiles = deviceBrowser.files.map { file in
            DeviceAudioFile(
                id: file.id,
                url: legacyURL(for: file, activeDestination: activeDestination),
                fileName: file.name,
                byteCount: file.size,
                modifiedDate: file.modifiedDate,
                folderName: file.locationDescription,
                mtpFileID: file.backendKind == .mtp ? file.objectID : nil,
                mtpTrackID: file.backendKind == .mtp ? file.objectID : nil
            )
        }

        let devicePlaylists = deviceBrowser.collections
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

        let storageInfo = deviceBrowser.storageInfo.map { info in
            StorageInfo(
                totalCapacity: info.totalCapacity,
                availableCapacity: info.availableCapacity,
                usedByAudioFiles: info.usedByFiles,
                audioFileCount: info.fileCount
            )
        }

        return LegacyDeviceSnapshot(
            deviceFiles: deviceFiles,
            devicePlaylists: devicePlaylists,
            storageInfo: storageInfo,
            selectedDeviceFileIDs: deviceBrowser.selectedFileIDs,
            deviceBrowseMessage: deviceBrowser.statusMessage
        )
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
        advancedStorageExplorerEnabled: Bool
    ) {
        let device = connectedUSBDevices.first
        let deviceName = connectedMTPDeviceName ?? device?.displayName ?? "Garmin watch"
        let deviceID = device?.dedupeKey ?? deviceName
        deviceBrowser.configure(backend: MTPDeviceFileSystem(deviceID: deviceID, displayName: deviceName))
        if deviceBrowser.browseMode == .advancedStorage && !advancedStorageExplorerEnabled {
            deviceBrowser.setBrowseMode(.musicOnly, advancedEnabled: false)
        }
    }

    private func legacyURL(for file: DeviceFile, activeDestination: URL?) -> URL {
        if file.backendKind == .mountedFolder, let activeDestination {
            return activeDestination.appendingPathComponent(file.path)
        }
        if let objectID = file.objectID, let url = URL(string: "mtp://file/\(objectID)") {
            return url
        }
        return URL(fileURLWithPath: file.name)
    }
}

struct LegacyDeviceSnapshot {
    let deviceFiles: [DeviceAudioFile]
    let devicePlaylists: [DevicePlaylist]
    let storageInfo: StorageInfo?
    let selectedDeviceFileIDs: Set<String>
    let deviceBrowseMessage: String?
}
