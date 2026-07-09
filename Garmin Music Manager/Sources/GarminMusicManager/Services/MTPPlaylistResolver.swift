import Foundation
import GarminMusicCore

/// Resolves which device track object IDs belong in a post-sync native playlist.
enum MTPPlaylistResolver {
    /// Tracks from the plan that should appear on the playlist (skipped-as-identical
    /// and successfully transferred items).
    ///
    /// Prefer `uploadedObjects` (object IDs returned by the helper) so a full
    /// post-sync library re-list is unnecessary. Fall back to `deviceFiles` for
    /// skip-identical rows and any upload whose object ID was not reported.
    ///
    /// `failedKeys` may contain display names and/or normalized remote paths.
    static func playlistTracks(
        plan: MTPSyncPlan,
        failedDisplayNames: Set<String>,
        deviceFiles: [DeviceFile],
        uploadedObjects: [DeviceUploadedObject] = []
    ) -> [DeviceFile] {
        let index = pathIndex(deviceFiles)
        let uploadIndex = uploadPathIndex(uploadedObjects)
        var result: [DeviceFile] = []
        var seenIDs = Set<String>()
        let failedNormalized = Set(failedDisplayNames.map { MTPSyncPlanner.normalizePath($0) })

        for item in plan.items {
            switch item.action {
            case .skipIdentical:
                break
            case .copy, .replace, .keepBoth:
                let pathKey = MTPSyncPlanner.normalizePath(item.targetRemotePath)
                if failedDisplayNames.contains(item.track.displayName)
                    || failedDisplayNames.contains(item.targetRemotePath)
                    || failedNormalized.contains(pathKey)
                    || (item.uploadFile.map { failedDisplayNames.contains($0.displayName) } ?? false)
                {
                    continue
                }
            }

            let file: DeviceFile?
            if let uploaded = matchUpload(path: item.targetRemotePath, in: uploadIndex) {
                file = deviceFile(from: uploaded, track: item.track)
            } else {
                file = match(path: item.targetRemotePath, in: index)
            }
            guard let file else { continue }
            let key = file.objectID ?? file.id
            guard seenIDs.insert(key).inserted else { continue }
            // Object ID is required for native MTP playlists.
            guard file.objectID.flatMap(UInt32.init) != nil else { continue }
            result.append(file)
        }
        return result
    }

    /// True when every non-failed plan item can be resolved to an object ID
    /// using `uploadedObjects` plus the pre-sync `deviceFiles` listing.
    static func canResolveWithoutRefresh(
        plan: MTPSyncPlan,
        failedDisplayNames: Set<String>,
        deviceFiles: [DeviceFile],
        uploadedObjects: [DeviceUploadedObject]
    ) -> Bool {
        let tracks = playlistTracks(
            plan: plan,
            failedDisplayNames: failedDisplayNames,
            deviceFiles: deviceFiles,
            uploadedObjects: uploadedObjects
        )
        let expected = plan.items.filter { item in
            switch item.action {
            case .skipIdentical:
                return true
            case .copy, .replace, .keepBoth:
                let pathKey = MTPSyncPlanner.normalizePath(item.targetRemotePath)
                if failedDisplayNames.contains(item.track.displayName)
                    || failedDisplayNames.contains(item.targetRemotePath)
                    || failedDisplayNames.contains(pathKey)
                    || (item.uploadFile.map { failedDisplayNames.contains($0.displayName) } ?? false)
                {
                    return false
                }
                return true
            }
        }.count
        return !tracks.isEmpty && tracks.count >= expected
    }

    private static func deviceFile(from upload: DeviceUploadedObject, track: AudioTrack) -> DeviceFile {
        DeviceFile(
            objectID: upload.objectID,
            name: (upload.remotePath as NSString).lastPathComponent,
            type: .audio,
            size: upload.size,
            path: upload.remotePath,
            backendKind: .mtp,
            audioMetadata: DeviceAudioMetadata(
                title: track.title,
                artist: track.artist,
                album: track.album,
                durationSeconds: track.durationSeconds
            )
        )
    }

    private static func pathIndex(_ files: [DeviceFile]) -> [String: DeviceFile] {
        var index: [String: DeviceFile] = [:]
        for file in files where file.type == .audio {
            let normalized = MTPSyncPlanner.normalizePath(file.path)
            index[normalized] = file
            let musicPrefixed = MTPSyncPlanner.normalizePath("Music/\(file.path)")
            if index[musicPrefixed] == nil {
                index[musicPrefixed] = file
            }
            if file.path.lowercased().hasPrefix("music/") {
                let without = String(file.path.dropFirst("music/".count))
                let n = MTPSyncPlanner.normalizePath(without)
                if index[n] == nil {
                    index[n] = file
                }
            }
        }
        return index
    }

    private static func uploadPathIndex(_ uploads: [DeviceUploadedObject]) -> [String: DeviceUploadedObject] {
        var index: [String: DeviceUploadedObject] = [:]
        for upload in uploads {
            guard upload.objectID != nil else { continue }
            let normalized = MTPSyncPlanner.normalizePath(upload.remotePath)
            index[normalized] = upload
            if upload.remotePath.lowercased().hasPrefix("music/") {
                let without = String(upload.remotePath.dropFirst("music/".count))
                let n = MTPSyncPlanner.normalizePath(without)
                if index[n] == nil {
                    index[n] = upload
                }
            }
            let musicPrefixed = MTPSyncPlanner.normalizePath("Music/\(upload.remotePath)")
            if index[musicPrefixed] == nil {
                index[musicPrefixed] = upload
            }
        }
        return index
    }

    private static func match(path: String, in index: [String: DeviceFile]) -> DeviceFile? {
        index[MTPSyncPlanner.normalizePath(path)]
    }

    private static func matchUpload(path: String, in index: [String: DeviceUploadedObject]) -> DeviceUploadedObject? {
        index[MTPSyncPlanner.normalizePath(path)]
    }
}
