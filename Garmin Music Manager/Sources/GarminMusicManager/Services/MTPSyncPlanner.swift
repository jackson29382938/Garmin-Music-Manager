import Foundation
import GarminMusicCore

struct MTPSyncPlanItem: Identifiable, Hashable {
    let id: UUID
    let track: AudioTrack
    let action: SyncPreviewItem.SyncAction
    let targetRemotePath: String
    let uploadFile: DeviceUploadFile?
    let deleteTarget: DeviceFile?

    init(
        track: AudioTrack,
        action: SyncPreviewItem.SyncAction,
        targetRemotePath: String,
        uploadFile: DeviceUploadFile? = nil,
        deleteTarget: DeviceFile? = nil
    ) {
        self.id = track.id
        self.track = track
        self.action = action
        self.targetRemotePath = targetRemotePath
        self.uploadFile = uploadFile
        self.deleteTarget = deleteTarget
    }
}

struct MTPSyncPlan {
    let items: [MTPSyncPlanItem]

    var previewItems: [SyncPreviewItem] {
        items.map { item in
            SyncPreviewItem(
                track: item.track,
                action: item.action,
                targetPath: "Garmin MTP/\(item.targetRemotePath)"
            )
        }
    }

    var totalBytesToTransfer: Int64 {
        items.reduce(Int64(0)) { partial, item in
            switch item.action {
            case .copy, .replace, .keepBoth:
                return partial + item.track.byteCount
            case .skipIdentical:
                return partial
            }
        }
    }

    var uploads: [DeviceUploadFile] {
        items.compactMap(\.uploadFile)
    }

    var deletions: [DeviceFile] {
        items.compactMap(\.deleteTarget)
    }

    var skippedCount: Int {
        items.filter { $0.action == .skipIdentical }.count
    }

    var transferCount: Int {
        items.filter { $0.action != .skipIdentical }.count
    }
}

enum MTPSyncPlanner {
    static func buildPlan(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        deviceFiles: [DeviceFile]
    ) -> MTPSyncPlan {
        let index = DeviceFileIndex(files: deviceFiles)
        var reservedPaths = index.allNormalizedPaths
        var items: [MTPSyncPlanItem] = []

        for track in tracks {
            let baseRemotePath = remotePath(for: track, playlistName: playlistName, settings: settings)
            let existing = index.file(atRemotePath: baseRemotePath)
            let action = resolveAction(
                track: track,
                existing: existing,
                settings: settings
            )

            switch action {
            case .skipIdentical:
                items.append(MTPSyncPlanItem(
                    track: track,
                    action: .skipIdentical,
                    targetRemotePath: baseRemotePath
                ))
            case .replace:
                let uploadPath = baseRemotePath
                reservedPaths.insert(normalizePath(uploadPath))
                items.append(MTPSyncPlanItem(
                    track: track,
                    action: .replace,
                    targetRemotePath: uploadPath,
                    uploadFile: Self.makeUploadFile(
                        for: track,
                        remotePath: uploadPath,
                        playlistName: playlistName,
                        replaceObjectID: existing?.objectID
                    ),
                    deleteTarget: existing
                ))
            case .keepBoth:
                let uploadPath = uniqueRemotePath(
                    preferredPath: baseRemotePath,
                    reservedPaths: &reservedPaths
                )
                items.append(MTPSyncPlanItem(
                    track: track,
                    action: .keepBoth,
                    targetRemotePath: uploadPath,
                    uploadFile: Self.makeUploadFile(for: track, remotePath: uploadPath, playlistName: playlistName)
                ))
            case .copy:
                let uploadPath = uniqueRemotePath(
                    preferredPath: baseRemotePath,
                    reservedPaths: &reservedPaths
                )
                items.append(MTPSyncPlanItem(
                    track: track,
                    action: .copy,
                    targetRemotePath: uploadPath,
                    uploadFile: Self.makeUploadFile(for: track, remotePath: uploadPath, playlistName: playlistName)
                ))
            }
        }

        return MTPSyncPlan(items: items)
    }

    static func playlistRelativePath(for track: AudioTrack, playlistName: String, settings: SyncSettings) -> String {
        let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
        var components: [String] = [cleanPlaylistName]
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

    static func remotePath(for track: AudioTrack, playlistName: String, settings: SyncSettings) -> String {
        "Music/\(playlistRelativePath(for: track, playlistName: playlistName, settings: settings))"
    }

    static func makeUploadFile(
        for track: AudioTrack,
        remotePath: String,
        playlistName: String,
        replaceObjectID: String? = nil
    ) -> DeviceUploadFile {
        let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
        return DeviceUploadFile(
            localPath: track.url.path,
            remotePath: remotePath,
            displayName: track.displayName,
            metadata: DeviceAudioMetadata(
                title: track.title,
                artist: track.artist,
                album: track.album ?? cleanPlaylistName,
                durationSeconds: track.durationSeconds
            ),
            replaceObjectID: replaceObjectID
        )
    }

    private static func resolveAction(
        track: AudioTrack,
        existing: DeviceFile?,
        settings: SyncSettings
    ) -> SyncPreviewItem.SyncAction {
        guard let existing else { return .copy }

        switch settings.overwritePolicy {
        case .skipIdentical:
            if isIdentical(track: track, existing: existing) {
                return .skipIdentical
            }
            return .replace
        case .replace:
            return .replace
        case .keepBoth:
            return .keepBoth
        }
    }

    private static func isIdentical(track: AudioTrack, existing: DeviceFile) -> Bool {
        TrackMatching.isIdentical(track: track, existing: existing)
    }

    private static func uniqueRemotePath(preferredPath: String, reservedPaths: inout Set<String>) -> String {
        let normalizedPreferred = normalizePath(preferredPath)
        if !reservedPaths.contains(normalizedPreferred) {
            reservedPaths.insert(normalizedPreferred)
            return preferredPath
        }

        let folder = (preferredPath as NSString).deletingLastPathComponent
        let fileName = (preferredPath as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension

        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidatePath = folder.isEmpty ? candidateName : "\(folder)/\(candidateName)"
            let normalizedCandidate = normalizePath(candidatePath)
            if !reservedPaths.contains(normalizedCandidate) {
                reservedPaths.insert(normalizedCandidate)
                return candidatePath
            }
        }

        let fallback = folder.isEmpty ? UUID().uuidString : "\(folder)/\(UUID().uuidString)"
        reservedPaths.insert(normalizePath(fallback))
        return fallback
    }

    static func normalizePath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

private struct DeviceFileIndex {
    private let byPath: [String: DeviceFile]

    var allNormalizedPaths: Set<String> {
        Set(byPath.keys)
    }

    init(files: [DeviceFile]) {
        var index: [String: DeviceFile] = [:]
        for file in files where file.type == .audio {
            let normalized = MTPSyncPlanner.normalizePath(file.path)
            index[normalized] = file
            let musicPrefixed = MTPSyncPlanner.normalizePath("Music/\(file.path)")
            if index[musicPrefixed] == nil {
                index[musicPrefixed] = file
            }
            if file.path.lowercased().hasPrefix("music/") {
                let withoutMusic = String(file.path.dropFirst("music/".count))
                let normalizedWithoutMusic = MTPSyncPlanner.normalizePath(withoutMusic)
                if index[normalizedWithoutMusic] == nil {
                    index[normalizedWithoutMusic] = file
                }
            }
        }
        byPath = index
    }

    func file(atRemotePath path: String) -> DeviceFile? {
        byPath[MTPSyncPlanner.normalizePath(path)]
    }
}
