import Foundation
import GarminMusicCore

/// Resolves which device track object IDs belong in a post-sync native playlist.
enum MTPPlaylistResolver {
    /// Tracks from the plan that should appear on the playlist (skipped-as-identical
    /// and successfully transferred items), matched against a fresh device listing.
    ///
    /// `failedKeys` may contain display names and/or normalized remote paths.
    static func playlistTracks(
        plan: MTPSyncPlan,
        failedDisplayNames: Set<String>,
        deviceFiles: [DeviceFile]
    ) -> [DeviceFile] {
        let index = pathIndex(deviceFiles)
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

            guard let file = match(path: item.targetRemotePath, in: index) else { continue }
            let key = file.objectID ?? file.id
            guard seenIDs.insert(key).inserted else { continue }
            result.append(file)
        }
        return result
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

    private static func match(path: String, in index: [String: DeviceFile]) -> DeviceFile? {
        index[MTPSyncPlanner.normalizePath(path)]
    }
}
