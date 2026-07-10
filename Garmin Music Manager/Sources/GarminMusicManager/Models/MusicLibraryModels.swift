import Foundation

/// A single track exposed by the Apple Music / Music.app library.
struct LibraryTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let location: URL?
    let isCloudOnly: Bool
    let isDRMProtected: Bool
    let fileExtension: String?

    /// A local, copyable file (present on disk, not cloud-only, not DRM-protected).
    var isImportable: Bool {
        guard let location, location.isFileURL else { return false }
        return !isCloudOnly && !isDRMProtected
    }

    var subtitle: String {
        [artist, album].compactMap { $0?.nilIfEmpty }.joined(separator: " • ")
    }
}

struct LibraryPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let trackIDs: [String]

    var trackCount: Int { trackIDs.count }
}

struct LibraryAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let trackIDs: [String]

    var trackCount: Int { trackIDs.count }
}

/// Aggregate snapshot loaded from the Apple Music library.
struct MusicLibrarySnapshot {
    let tracksByID: [String: LibraryTrack]
    let playlists: [LibraryPlaylist]
    let albums: [LibraryAlbum]

    static let empty = MusicLibrarySnapshot(tracksByID: [:], playlists: [], albums: [])

    func importableURLs(for trackIDs: [String]) -> [URL] {
        trackIDs.compactMap { id in
            guard let track = tracksByID[id], track.isImportable else { return nil }
            return track.location
        }
    }

    func tracks(for trackIDs: [String]) -> [LibraryTrack] {
        trackIDs.compactMap { tracksByID[$0] }
    }
}

enum MusicLibraryStatus: Equatable {
    case idle
    case loading
    case loaded(playlistCount: Int, albumCount: Int, trackCount: Int)
    case unavailable(String)

    var message: String {
        switch self {
        case .idle:
            return "Not loaded yet."
        case .loading:
            return "Loading Apple Music library…"
        case let .loaded(playlistCount, albumCount, trackCount):
            return "\(playlistCount) playlists, \(albumCount) albums, \(trackCount) tracks."
        case let .unavailable(reason):
            return reason
        }
    }
}

enum LibraryTrackSort: String, CaseIterable, Identifiable {
    case titleAscending = "Title A–Z"
    case titleDescending = "Title Z–A"
    case artistAscending = "Artist A–Z"
    case artistDescending = "Artist Z–A"
    case albumAscending = "Album A–Z"
    case albumDescending = "Album Z–A"
    case importableFirst = "Importable first"
    case nonImportableFirst = "Cloud/DRM first"
    case extensionAscending = "Format A–Z"
    case extensionDescending = "Format Z–A"

    var id: String { rawValue }
}

enum LibraryTrackAvailabilityFilter: String, CaseIterable, Identifiable {
    case all = "All tracks"
    case importableOnly = "Importable only"
    case cloudOnly = "Cloud only"
    case drmProtected = "DRM protected"
    case nonImportable = "Non-importable"
    case localFiles = "Local files"

    var id: String { rawValue }
}

enum LibraryTrackFormatFilter: String, CaseIterable, Identifiable {
    case all = "Any format"
    case mp3 = "MP3"
    case aac = "AAC / M4A"
    case alac = "ALAC"
    case flac = "FLAC"
    case wav = "WAV"
    case aiff = "AIFF"
    case other = "Other formats"

    var id: String { rawValue }

    func matches(extension fileExtension: String?) -> Bool {
        let ext = (fileExtension ?? "").lowercased()
        switch self {
        case .all:
            return true
        case .mp3:
            return ext == "mp3"
        case .aac:
            return ext == "m4a" || ext == "aac" || ext == "mp4"
        case .alac:
            return ext == "alac"
        case .flac:
            return ext == "flac"
        case .wav:
            return ext == "wav" || ext == "wave"
        case .aiff:
            return ext == "aiff" || ext == "aif"
        case .other:
            let known: Set<String> = ["mp3", "m4a", "aac", "mp4", "alac", "flac", "wav", "wave", "aiff", "aif"]
            return !known.contains(ext)
        }
    }
}

enum LibraryTrackMetadataFilter: String, CaseIterable, Identifiable {
    case all = "Any metadata"
    case hasArtist = "Has artist"
    case missingArtist = "Missing artist"
    case hasAlbum = "Has album"
    case missingAlbum = "Missing album"
    case hasArtistAndAlbum = "Has artist & album"

    var id: String { rawValue }
}

struct LibraryTrackBrowserFilters: Equatable {
    var availability: LibraryTrackAvailabilityFilter = .all
    var format: LibraryTrackFormatFilter = .all
    var metadata: LibraryTrackMetadataFilter = .all

    var isDefault: Bool {
        availability == .all && format == .all && metadata == .all
    }

    var activeLabels: [String] {
        var labels: [String] = []
        if availability != .all { labels.append(availability.rawValue) }
        if format != .all { labels.append(format.rawValue) }
        if metadata != .all { labels.append(metadata.rawValue) }
        return labels
    }

    func matches(_ track: LibraryTrack) -> Bool {
        switch availability {
        case .all:
            break
        case .importableOnly:
            guard track.isImportable else { return false }
        case .cloudOnly:
            guard track.isCloudOnly else { return false }
        case .drmProtected:
            guard track.isDRMProtected else { return false }
        case .nonImportable:
            guard !track.isImportable else { return false }
        case .localFiles:
            guard let location = track.location, location.isFileURL, !track.isCloudOnly else { return false }
        }

        guard format.matches(extension: track.fileExtension) else { return false }

        let hasArtist = !(track.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasAlbum = !(track.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        switch metadata {
        case .all:
            return true
        case .hasArtist:
            return hasArtist
        case .missingArtist:
            return !hasArtist
        case .hasAlbum:
            return hasAlbum
        case .missingAlbum:
            return !hasAlbum
        case .hasArtistAndAlbum:
            return hasArtist && hasAlbum
        }
    }
}

extension Array where Element == LibraryTrack {
    func sorted(by sort: LibraryTrackSort) -> [LibraryTrack] {
        switch sort {
        case .titleAscending:
            return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDescending:
            return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .artistAscending:
            return sorted {
                if let primary = compareOptional($0.artist, $1.artist, ascending: true) {
                    return primary
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .artistDescending:
            return sorted {
                if let primary = compareOptional($0.artist, $1.artist, ascending: false) {
                    return primary
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .albumAscending:
            return sorted {
                if let primary = compareOptional($0.album, $1.album, ascending: true) {
                    return primary
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .albumDescending:
            return sorted {
                if let primary = compareOptional($0.album, $1.album, ascending: false) {
                    return primary
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .importableFirst:
            return sorted {
                if $0.isImportable != $1.isImportable { return $0.isImportable && !$1.isImportable }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .nonImportableFirst:
            return sorted {
                if $0.isImportable != $1.isImportable { return !$0.isImportable && $1.isImportable }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .extensionAscending:
            return sorted {
                if let primary = compareOptional($0.fileExtension, $1.fileExtension, ascending: true) {
                    return primary
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .extensionDescending:
            return sorted {
                if let primary = compareOptional($0.fileExtension, $1.fileExtension, ascending: false) {
                    return primary
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }
}

private func compareOptional(_ lhs: String?, _ rhs: String?, ascending: Bool) -> Bool? {
    let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if left.isEmpty != right.isEmpty {
        // Empty values sort last in both directions for readability.
        return right.isEmpty
    }
    let order = left.localizedCaseInsensitiveCompare(right)
    if order == .orderedSame { return nil }
    return ascending ? order == .orderedAscending : order == .orderedDescending
}
