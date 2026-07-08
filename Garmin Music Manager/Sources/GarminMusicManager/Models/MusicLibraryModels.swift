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
