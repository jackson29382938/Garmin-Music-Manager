import Foundation
import GarminMusicCore

/// A discovered local audio file plus its Garmin compatibility verdict.
/// Metadata-free so it works identically on Windows, macOS, and Linux (no
/// AVFoundation dependency); compatibility comes from the shared engine.
struct LibraryTrack: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var fileName: String
    var fileExtension: String
    var byteCount: Int64
    var compatibility: TrackCompatibility

    init(url: URL, byteCount: Int64, compatibility: TrackCompatibility) {
        self.id = UUID()
        self.url = url
        self.fileName = url.lastPathComponent
        self.fileExtension = url.pathExtension.lowercased()
        self.byteCount = byteCount
        self.compatibility = compatibility
    }

    var statusText: String { compatibility.status.rawValue }
    var detail: String { compatibility.messages.first ?? "" }
}

/// A file already present in the destination ("On Watch") folder.
struct WatchFile: Identifiable, Hashable {
    let id: UUID
    var name: String
    var relativePath: String
    var byteCount: Int64
    var isAudio: Bool

    init(name: String, relativePath: String, byteCount: Int64, isAudio: Bool) {
        self.id = UUID()
        self.name = name
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.isAudio = isAudio
    }
}

enum OrganizationChoice: String, CaseIterable {
    case flat = "Flat"
    case byArtist = "By artist"
    case byArtistAlbum = "By artist / album"

    var resolver: SyncPathResolver.Organization {
        switch self {
        case .flat: return .flat
        case .byArtist: return .byArtist
        case .byArtistAlbum: return .byArtistAlbum
        }
    }
}

enum OverwriteChoice: String, CaseIterable {
    case skipIdentical = "Skip identical"
    case replace = "Replace"
    case keepBoth = "Keep both"
}

/// Human-readable byte size (decimal units), cross-platform without ByteCountFormatter.
func formatBytes(_ bytes: Int64) -> String {
    let value = Double(max(bytes, 0))
    let units = ["B", "KB", "MB", "GB", "TB"]
    var index = 0
    var scaled = value
    while scaled >= 1000, index < units.count - 1 {
        scaled /= 1000
        index += 1
    }
    if index == 0 {
        return "\(Int(scaled)) \(units[index])"
    }
    return String(format: "%.1f %@", scaled, units[index])
}
