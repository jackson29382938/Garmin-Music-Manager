import Foundation
import GarminMusicCore

/// Shared rules for “same track already on device” (sync skip + UI duplicate badges).
enum TrackMatching {
    /// Size must match exactly when both sides report a positive size.
    static func sizesMatch(local: Int64, remote: Int64) -> Bool {
        guard local > 0, remote > 0 else { return false }
        return local == remote
    }

    /// Duration within ±1.5s when both are known.
    static func durationsMatch(local: Double?, remote: Double?) -> Bool {
        guard let local, let remote, local.isFinite, remote.isFinite, local > 0, remote > 0 else {
            return false
        }
        return abs(local - remote) <= 1.5
    }

    static func namesMatch(localFileName: String, remoteFileName: String) -> Bool {
        localFileName.localizedCaseInsensitiveCompare(remoteFileName) == .orderedSame
    }

    static func metadataTitlesMatch(localTitle: String?, remoteTitle: String?) -> Bool {
        guard let local = localTitle?.nilIfEmpty, let remote = remoteTitle?.nilIfEmpty else {
            return false
        }
        return local.localizedCaseInsensitiveCompare(remote) == .orderedSame
    }

    static func artistsMatch(local: String?, remote: String?) -> Bool {
        guard let local = local?.nilIfEmpty, let remote = remote?.nilIfEmpty else {
            return false
        }
        return local.localizedCaseInsensitiveCompare(remote) == .orderedSame
    }

    /// True when the local track is considered already present as `existing`.
    static func isIdentical(
        localFileName: String,
        localByteCount: Int64,
        localTitle: String?,
        localArtist: String?,
        localDuration: Double?,
        existingName: String,
        existingSize: Int64,
        existingTitle: String?,
        existingArtist: String?,
        existingDuration: Double?
    ) -> Bool {
        let sizeOK = sizesMatch(local: localByteCount, remote: existingSize)

        // Strongest: filename + size (original rule).
        if sizeOK, namesMatch(localFileName: localFileName, remoteFileName: existingName) {
            return true
        }

        // Metadata: title + artist + size (handles renames on disk).
        if sizeOK,
           metadataTitlesMatch(localTitle: localTitle, remoteTitle: existingTitle),
           artistsMatch(local: localArtist, remote: existingArtist) {
            return true
        }

        // Title + duration + size when artist missing on one side.
        if sizeOK,
           metadataTitlesMatch(localTitle: localTitle, remoteTitle: existingTitle),
           durationsMatch(local: localDuration, remote: existingDuration) {
            return true
        }

        return false
    }

    static func isIdentical(track: AudioTrack, existing: DeviceFile) -> Bool {
        isIdentical(
            localFileName: FileNameSanitizer.safeFileName(for: track),
            localByteCount: track.byteCount,
            localTitle: track.title,
            localArtist: track.artist,
            localDuration: track.durationSeconds,
            existingName: existing.name,
            existingSize: existing.size,
            existingTitle: existing.audioMetadata?.title,
            existingArtist: existing.audioMetadata?.artist,
            existingDuration: existing.audioMetadata?.durationSeconds
        )
    }

    /// Fingerprint keys used for bulk duplicate indexing on the device listing.
    static func deviceFingerprintKeys(for file: DeviceFile) -> [String] {
        var keys: [String] = []
        keys.append("name|\(file.name.lowercased())|\(file.size)")
        if let title = file.audioMetadata?.title?.nilIfEmpty?.lowercased() {
            let artist = file.audioMetadata?.artist?.nilIfEmpty?.lowercased() ?? ""
            keys.append("meta|\(artist)|\(title)|\(file.size)")
            if let duration = file.audioMetadata?.durationSeconds, duration > 0 {
                keys.append("td|\(title)|\(Int(duration.rounded()))|\(file.size)")
            }
        }
        return keys
    }

    static func trackFingerprintKeys(for track: AudioTrack) -> [String] {
        var keys: [String] = []
        let safe = FileNameSanitizer.safeFileName(for: track).lowercased()
        keys.append("name|\(safe)|\(track.byteCount)")
        keys.append("name|\(track.fileName.lowercased())|\(track.byteCount)")
        if let title = track.title?.nilIfEmpty?.lowercased() {
            let artist = track.artist?.nilIfEmpty?.lowercased() ?? ""
            keys.append("meta|\(artist)|\(title)|\(track.byteCount)")
            if let duration = track.durationSeconds, duration > 0 {
                keys.append("td|\(title)|\(Int(duration.rounded()))|\(track.byteCount)")
            }
        }
        return keys
    }
}
