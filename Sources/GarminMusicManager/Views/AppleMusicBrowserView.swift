import SwiftUI

struct AppleMusicBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Category: String, CaseIterable, Identifiable {
        case playlists = "Playlists"
        case albums = "Albums"
        var id: String { rawValue }
    }

    @State private var category: Category = .playlists
    @State private var selectedPlaylistID: String?
    @State private var selectedAlbumID: String?
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        HStack {
            Text("Apple Music Library")
                .font(.title2.bold())
            Spacer()
            Button {
                model.loadAppleMusicLibrary()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            Button {
                dismiss()
                model.showAppleMusicBrowser = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.musicLibraryStatus {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(model.musicLibraryStatus.message)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .unavailable(reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Apple Music library unavailable")
                    .font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        VStack(spacing: 8) {
            Picker("Category", selection: $category) {
                ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            NavigationSplitView {
                collectionList
                    .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 340)
            } detail: {
                trackList
            }
        }
    }

    @ViewBuilder
    private var collectionList: some View {
        switch category {
        case .playlists:
            List(filteredPlaylists, selection: $selectedPlaylistID) { playlist in
                VStack(alignment: .leading) {
                    Text(playlist.name)
                    Text("\(playlist.trackCount) tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(Optional(playlist.id))
            }
        case .albums:
            List(filteredAlbums, selection: $selectedAlbumID) { album in
                VStack(alignment: .leading) {
                    Text(album.title)
                    Text([album.artist, "\(album.trackCount) tracks"].compactMap { $0 }.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(Optional(album.id))
            }
        }
    }

    private var trackList: some View {
        let tracks = currentTracks
        return Group {
            if tracks.isEmpty {
                Text("Select a \(category == .playlists ? "playlist" : "album") to view its tracks.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tracks) { track in
                    HStack {
                        Image(systemName: track.isImportable ? "checkmark.circle.fill" : "icloud.slash")
                            .foregroundStyle(track.isImportable ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(track.title)
                            Text(track.subtitle.isEmpty ? "—" : track.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !track.isImportable {
                            Text(track.isDRMProtected ? "DRM" : "Cloud only")
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(importSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Import Selection") {
                model.importLibraryTracks(currentTrackIDs)
            }
            .buttonStyle(.borderedProminent)
            .disabled(importableCount == 0)
        }
        .padding()
    }

    private var filteredPlaylists: [LibraryPlaylist] {
        guard !search.isEmpty else { return model.musicLibrary.playlists }
        return model.musicLibrary.playlists.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var filteredAlbums: [LibraryAlbum] {
        guard !search.isEmpty else { return model.musicLibrary.albums }
        return model.musicLibrary.albums.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || ($0.artist?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var currentTrackIDs: [String] {
        switch category {
        case .playlists:
            return model.musicLibrary.playlists.first { $0.id == selectedPlaylistID }?.trackIDs ?? []
        case .albums:
            return model.musicLibrary.albums.first { $0.id == selectedAlbumID }?.trackIDs ?? []
        }
    }

    private var currentTracks: [LibraryTrack] {
        model.musicLibrary.tracks(for: currentTrackIDs)
    }

    private var importableCount: Int {
        currentTracks.filter { $0.isImportable }.count
    }

    private var importSummary: String {
        let total = currentTracks.count
        guard total > 0 else { return "No selection" }
        return "\(importableCount) of \(total) tracks importable (local, non-DRM)"
    }
}
