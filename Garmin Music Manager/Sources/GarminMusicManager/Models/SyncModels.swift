import Foundation

/// Structured progress for Transfer UI (N of M, track name, percent).
struct TransferProgressSnapshot: Equatable, Sendable {
    var fraction: Double
    var message: String?
    var itemIndex: Int?
    var itemCount: Int?
    var itemName: String?
    var bytesTransferred: Int64?
    var bytesTotal: Int64?

    init(
        fraction: Double,
        message: String? = nil,
        itemIndex: Int? = nil,
        itemCount: Int? = nil,
        itemName: String? = nil,
        bytesTransferred: Int64? = nil,
        bytesTotal: Int64? = nil
    ) {
        self.fraction = min(1, max(0, fraction))
        self.message = message
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.itemName = itemName
        self.bytesTransferred = bytesTransferred
        self.bytesTotal = bytesTotal
    }

    /// Convenience for phase-only updates (prepare, playlist, refresh).
    static func phase(_ fraction: Double, _ message: String?) -> TransferProgressSnapshot {
        TransferProgressSnapshot(fraction: fraction, message: message)
    }

    /// "3 of 12 · Song.mp3" when index/count known.
    var itemLabel: String? {
        guard let itemCount, itemCount > 0, let itemIndex else {
            if let itemName, !itemName.isEmpty { return itemName }
            return nil
        }
        let n = min(itemIndex + 1, itemCount)
        if let itemName, !itemName.isEmpty {
            return "\(n) of \(itemCount) · \(itemName)"
        }
        return "\(n) of \(itemCount)"
    }

    var percentLabel: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    var bytesLabel: String? {
        guard let bytesTransferred, let bytesTotal, bytesTotal > 0 else { return nil }
        let done = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
        return "\(done) / \(total)"
    }

    /// Prefer structured label, then free-form message.
    var primaryLine: String {
        if let itemLabel { return itemLabel }
        if let message, !message.isEmpty { return message }
        return "Transferring…"
    }
}

struct SyncResult {
    let copiedCount: Int
    let skippedCount: Int
    let replacedCount: Int
    let playlistURL: URL
    let targetFolder: URL
}

struct MTPSyncResult {
    let uploadedCount: Int
    let skippedCount: Int
    let replacedCount: Int
    let failedCount: Int
    /// True when the owning Task was cancelled mid-transfer (remaining items not treated as failures).
    let wasCancelled: Bool
    /// Native MTP playlist name when one was created or updated successfully.
    let playlistName: String?
    /// Remote paths (or display names) that failed to transfer.
    let failedItems: [String]
    /// Tracks that failed transfer (stable Mac queue IDs).
    let failedTrackIDs: [UUID]
    /// Tracks never attempted because of cancel / early stop (stable Mac queue IDs).
    let remainingTrackIDs: [UUID]

    init(
        uploadedCount: Int,
        skippedCount: Int,
        replacedCount: Int,
        failedCount: Int,
        wasCancelled: Bool = false,
        playlistName: String? = nil,
        failedItems: [String] = [],
        failedTrackIDs: [UUID] = [],
        remainingTrackIDs: [UUID] = []
    ) {
        self.uploadedCount = uploadedCount
        self.skippedCount = skippedCount
        self.replacedCount = replacedCount
        self.failedCount = failedCount
        self.wasCancelled = wasCancelled
        self.playlistName = playlistName
        self.failedItems = failedItems
        self.failedTrackIDs = failedTrackIDs
        self.remainingTrackIDs = remainingTrackIDs
    }

    /// Failed + not-yet-attempted IDs for “Retry / continue send”.
    var retryTrackIDs: [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for id in failedTrackIDs + remainingTrackIDs {
            if seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    var canRetryFailed: Bool { !retryTrackIDs.isEmpty }
}

/// Result of preparing tracks for sync (optional ALAC/FLAC → AAC conversion).
struct TrackPreparationResult {
    let tracks: [AudioTrack]
    /// Human-readable lines for tracks that still need conversion or failed to convert.
    let conversionFailures: [String]
    let convertedCount: Int

    var hasConversionIssues: Bool { !conversionFailures.isEmpty }
}

struct SyncPreviewItem: Identifiable, Hashable {
    let id = UUID()
    let track: AudioTrack
    let action: SyncAction
    let targetPath: String

    enum SyncAction: String, Hashable {
        case copy = "Copy"
        case skipIdentical = "Skip (identical)"
        case replace = "Replace"
        case keepBoth = "Keep both"
    }
}

struct SyncPreview {
    let items: [SyncPreviewItem]
    let totalBytesToCopy: Int64

    var copyCount: Int { items.filter { $0.action == .copy || $0.action == .replace || $0.action == .keepBoth }.count }
    var skipCount: Int { items.filter { $0.action == .skipIdentical }.count }
}

enum OverwritePolicy: String, CaseIterable, Identifiable, Codable {
    case skipIdentical = "Skip identical files"
    case replace = "Replace existing files"
    case keepBoth = "Keep both (rename new)"

    var id: String { rawValue }
}

enum OrganizationPolicy: String, CaseIterable, Identifiable, Codable {
    case flat = "Flat folder"
    case byArtist = "Artist folders"
    case byArtistAlbum = "Artist / Album folders"

    var id: String { rawValue }
}

enum GarminDestinationMode: String, CaseIterable, Identifiable, Codable {
    case autoDetected
    case customFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autoDetected:
            return "Auto-detected Garmin Music"
        case .customFolder:
            return "Custom Folder"
        }
    }
}

struct GarminFolderTarget: Hashable {
    let storagePath: String

    init(_ path: String, defaultingTo defaultPath: String = "Music") {
        self.storagePath = Self.normalizedStoragePath(path, defaultingTo: defaultPath)
    }

    static func defaultMovePath(playlistName: String) -> String {
        "Music/\(FileNameSanitizer.sanitizePathComponent(playlistName.nilIfEmpty ?? "Garmin Playlist"))"
    }

    static func normalizedStoragePath(_ path: String, defaultingTo defaultPath: String = "Music") -> String {
        let components = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { FileNameSanitizer.sanitizePathComponent(String($0)) }
            .filter { !$0.isEmpty && $0 != "." }

        let fallback = defaultPath.nilIfEmpty ?? "Music"
        return components.isEmpty ? fallback : components.joined(separator: "/")
    }

    func destinationURL(relativeTo mountedRoot: URL) -> URL {
        var components = storagePath.split(separator: "/").map(String.init)
        if mountedRoot.lastPathComponent.localizedCaseInsensitiveCompare("Music") == .orderedSame,
           components.first?.localizedCaseInsensitiveCompare("Music") == .orderedSame {
            components.removeFirst()
        }

        return components.reduce(mountedRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    func remotePath(for fileName: String) -> String {
        let safeName = FileNameSanitizer.sanitizeFileName(fileName, fallback: "Garmin Track")
        return "\(storagePath)/\(safeName)"
    }
}

struct SyncSettings: Codable, Equatable {
    var overwritePolicy: OverwritePolicy
    var organizationPolicy: OrganizationPolicy
    var writePlaylist: Bool
    var convertIncompatibleFormats: Bool

    static let `default` = SyncSettings(
        overwritePolicy: .skipIdentical,
        organizationPolicy: .flat,
        writePlaylist: true,
        convertIncompatibleFormats: false
    )
}

struct DeviceAudioFile: Identifiable, Hashable {
    let id: String
    let url: URL
    let fileName: String
    let byteCount: Int64
    let modifiedDate: Date?
    var folderName: String? = nil
    var mtpFileID: String? = nil
    var mtpTrackID: String? = nil

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct DevicePlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let trackFileNames: [String]
    let source: Source

    enum Source: String, Hashable {
        case m3u8
        case folder
        case mtpPlaylist
    }

    var trackCount: Int { trackFileNames.count }
}

enum DeviceFileSort: String, CaseIterable, Identifiable, Codable {
    case nameAscending = "Name A–Z"
    case nameDescending = "Name Z–A"
    case sizeAscending = "Size (smallest)"
    case sizeDescending = "Size (largest)"
    case folderAscending = "Folder A–Z"

    var id: String { rawValue }
}

struct StorageInfo {
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let usedByAudioFiles: Int64
    let audioFileCount: Int

    var usedCapacity: Int64? {
        guard let totalCapacity, let availableCapacity else { return nil }
        return max(0, totalCapacity - availableCapacity)
    }

    var availableDescription: String {
        guard let availableCapacity else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)
    }

    var totalDescription: String {
        guard let totalCapacity else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: totalCapacity, countStyle: .file)
    }

    var audioSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: usedByAudioFiles, countStyle: .file)
    }
}
