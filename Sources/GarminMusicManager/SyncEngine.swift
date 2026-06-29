import Foundation

enum MusicSyncEngine {
    static func sync(plan: SyncPlan, log: (LogLevel, String, String?) -> Void) throws -> SyncResult {
        if plan.useMTP {
            return try syncViaMTP(plan: plan, log: log)
        }
        return try syncToMountedFolder(plan: plan, log: log)
    }

    private static func syncToMountedFolder(plan: SyncPlan, log: (LogLevel, String, String?) -> Void) throws -> SyncResult {
        guard let syncFolderURL = plan.syncFolderURL, let playlistURL = plan.playlistURL else {
            throw AppError.noDestination
        }

        try FileManager.default.createDirectory(at: syncFolderURL, withIntermediateDirectories: true)
        try FileManager.default.verifyWritableDirectory(syncFolderURL)

        var playlistLines = ["#EXTM3U"]
        var copied = 0
        var failures: [String] = []

        for entry in plan.entries {
            do {
                if FileManager.default.fileExists(atPath: entry.destinationURL.path) {
                    try FileManager.default.removeItem(at: entry.destinationURL)
                }
                try FileManager.default.copyItem(at: entry.track.sourceURLForSync, to: entry.destinationURL)
                copied += 1

                let extInfDuration = entry.track.duration.map { String(Int($0.rounded())) } ?? "-1"
                playlistLines.append("#EXTINF:\(extInfDuration),\(entry.track.playlistDisplayName)")
                playlistLines.append(entry.destinationURL.lastPathComponent)
                log(.info, "Copied track", "\(entry.track.sourceURLForSync.path) -> \(entry.destinationURL.path)")
            } catch {
                let message = "Failed to copy \(entry.track.fileName): \(error.localizedDescription)"
                failures.append(message)
                log(.error, message, String(describing: error))
            }
        }

        do {
            try playlistLines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)
            log(.info, "Wrote playlist", playlistURL.path)
        } catch {
            let message = "Failed to write playlist: \(error.localizedDescription)"
            failures.append(message)
            log(.error, message, String(describing: error))
        }

        return SyncResult(copied: copied, failed: failures.count, playlistURL: playlistURL, failures: failures)
    }

    private static func syncViaMTP(plan: SyncPlan, log: (LogLevel, String, String?) -> Void) throws -> SyncResult {
        guard ExperimentalMTPBackend.isAvailable else {
            throw AppError.mtpUnavailable(ExperimentalMTPBackend.statusText)
        }

        var copied = 0
        var failures: [String] = []

        for entry in plan.entries {
            let remoteFileName = FileNameSanitizer.safeFileName(for: entry.track)
            do {
                let result = try ExperimentalMTPBackend.sendFile(entry.track.sourceURLForSync, remoteFileName: remoteFileName)
                copied += 1
                log(.info, "Sent track through MTP", "\(entry.track.sourceURLForSync.path) -> \(remoteFileName)\n\(result.combinedOutput)")
            } catch {
                let message = "MTP send failed for \(entry.track.fileName): \(error.localizedDescription)"
                failures.append(message)
                log(.error, message, String(describing: error))
            }
        }

        return SyncResult(copied: copied, failed: failures.count, playlistURL: nil, failures: failures)
    }
}
