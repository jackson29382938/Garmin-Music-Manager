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
            Label("Apple Music Library", systemImage: "music.note.list")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.panelAccent(for: .mac))
                .lineLimit(1)
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
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text([album.artist, "\(album.trackCount) tracks"].compactMap { $0 }.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            trackImportIcon(for: track)
                            trackText(for: track)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            importabilityBadge(for: track)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                trackImportIcon(for: track)
                                trackText(for: track)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                        }
                            importabilityBadge(for: track)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Label("Adds local, non-DRM tracks to your Transfer queue. Then tap Send to Watch.", systemImage: "arrow.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack {
                    importSummaryText
                    Spacer()
                    importButton
                }

                VStack(alignment: .trailing, spacing: 8) {
                    importSummaryText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    importButton
                }
            }
        }
        .padding()
    }

    private func trackImportIcon(for track: LibraryTrack) -> some View {
        Image(systemName: track.isImportable ? "checkmark.circle.fill" : "icloud.slash")
            .foregroundStyle(track.isImportable ? .green : .orange)
    }

    private func trackText(for track: LibraryTrack) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(track.subtitle.isEmpty ? "—" : track.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func importabilityBadge(for track: LibraryTrack) -> some View {
        if !track.isImportable {
            Text(track.isDRMProtected ? "DRM" : "Cloud only")
                .font(.caption2.bold())
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private var importSummaryText: some View {
        Text(importSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var importButton: some View {
        Button(actionTitle) {
            switch category {
            case .playlists:
                if let selectedPlaylistID {
                    model.prepareAppleMusicPlaylistForSync(selectedPlaylistID)
                }
            case .albums:
                model.importLibraryTracks(currentTrackIDs)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(importableCount == 0)
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

    private var actionTitle: String {
        "Add to Transfer queue"
    }
}
