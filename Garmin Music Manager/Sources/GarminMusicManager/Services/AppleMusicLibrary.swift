import Foundation

#if canImport(iTunesLibrary)
import iTunesLibrary
#endif

/// Reads the local Apple Music / Music.app library via the `iTunesLibrary`
/// framework. Only local, non-DRM, non-cloud-only audio tracks are exposed as
/// importable, since those are the only files that can be copied to a watch.
final class AppleMusicLibrary {
    enum LoadError: LocalizedError {
        case frameworkUnavailable
        case accessDenied(String)

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable:
                return "The iTunesLibrary framework is unavailable on this system."
            case let .accessDenied(detail):
                return detail
            }
        }
    }

    func loadSnapshot() throws -> MusicLibrarySnapshot {
        #if canImport(iTunesLibrary)
        let library: ITLibrary
        do {
            library = try ITLibrary(apiVersion: "1.1")
        } catch {
            throw LoadError.accessDenied(
                "Could not open the Apple Music library. Grant access under System Settings → Privacy & Security → Media & Apple Music. (\(error.localizedDescription))"
            )
        }

        var tracksByID: [String: LibraryTrack] = [:]

        for item in library.allMediaItems {
            guard item.mediaKind == .kindSong else { continue }
            let id = item.persistentID.stringValue
            let location = item.location
            let isFile = item.locationType == .file && (location?.isFileURL ?? false)
            let track = LibraryTrack(
                id: id,
                title: item.title,
                artist: item.artist?.name,
                album: item.album.title,
                location: isFile ? location : nil,
                isCloudOnly: item.isCloud && !isFile,
                isDRMProtected: item.isDRMProtected,
                fileExtension: location?.pathExtension.lowercased().nilIfEmpty
            )
            tracksByID[id] = track
        }

        var playlists: [LibraryPlaylist] = []
        for playlist in library.allPlaylists {
            guard playlist.isVisible else { continue }
            guard playlist.distinguishedKind == .kindNone || playlist.distinguishedKind == .kindMusic else { continue }
            let trackIDs = playlist.items
                .filter { $0.mediaKind == .kindSong }
                .map { $0.persistentID.stringValue }
            guard !trackIDs.isEmpty else { continue }
            playlists.append(LibraryPlaylist(id: playlist.persistentID.stringValue, name: playlist.name, trackIDs: trackIDs))
        }
        playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let albums = buildAlbums(from: tracksByID, library: library)

        return MusicLibrarySnapshot(tracksByID: tracksByID, playlists: playlists, albums: albums)
        #else
        throw LoadError.frameworkUnavailable
        #endif
    }

    #if canImport(iTunesLibrary)
    private func buildAlbums(from tracksByID: [String: LibraryTrack], library: ITLibrary) -> [LibraryAlbum] {
        var grouping: [String: (title: String, artist: String?, ids: [String])] = [:]

        for item in library.allMediaItems {
            guard item.mediaKind == .kindSong else { continue }
            let albumTitle = item.album.title?.nilIfEmpty ?? "Unknown Album"
            let albumArtist = item.album.albumArtist?.nilIfEmpty ?? item.artist?.name?.nilIfEmpty
            let key = "\(albumTitle.lowercased())|\((albumArtist ?? "").lowercased())"
            let id = item.persistentID.stringValue
            grouping[key, default: (albumTitle, albumArtist, [])].ids.append(id)
        }

        return grouping.values
            .map { LibraryAlbum(id: "\($0.title)|\($0.artist ?? "")", title: $0.title, artist: $0.artist, trackIDs: $0.ids) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    #endif
}
