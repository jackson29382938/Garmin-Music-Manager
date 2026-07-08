import Foundation
import GarminMusicCore

struct AudioTrack: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let fileName: String
    let fileExtension: String
    let title: String?
    let artist: String?
    let album: String?
    let durationSeconds: Double?
    let byteCount: Int64
    let codecHint: String?
    let compatibility: TrackCompatibility
    var isSelected: Bool
    var isDuplicateOnDevice: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        fileExtension: String,
        title: String?,
        artist: String?,
        album: String?,
        durationSeconds: Double?,
        byteCount: Int64,
        codecHint: String?,
        compatibility: TrackCompatibility,
        isSelected: Bool = true,
        isDuplicateOnDevice: Bool = false
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.codecHint = codecHint
        self.compatibility = compatibility
        self.isSelected = isSelected
        self.isDuplicateOnDevice = isDuplicateOnDevice
    }

    var displayName: String {
        if let title, !title.isEmpty {
            if let artist, !artist.isEmpty {
                return "\(artist) — \(title)"
            }
            return title
        }
        return fileName
    }

    var playlistDisplayName: String {
        if let artist, !artist.isEmpty {
            return "\(artist) - \(displayName.replacingOccurrences(of: "\(artist) — ", with: ""))"
        }
        return displayName
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var durationDescription: String {
        guard let durationSeconds, durationSeconds.isFinite else { return "—" }
        return DurationFormatter.format(durationSeconds)
    }

    var organizationFolderComponents: [String] {
        var components: [String] = []
        if let artist = artist?.nilIfEmpty {
            components.append(FileNameSanitizer.sanitizePathComponent(artist))
        }
        if let album = album?.nilIfEmpty {
            components.append(FileNameSanitizer.sanitizePathComponent(album))
        }
        return components
    }
}
