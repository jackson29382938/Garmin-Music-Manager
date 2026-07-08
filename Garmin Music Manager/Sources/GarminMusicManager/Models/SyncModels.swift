import Foundation

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

enum DeviceFileSort: String, CaseIterable, Identifiable {
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
