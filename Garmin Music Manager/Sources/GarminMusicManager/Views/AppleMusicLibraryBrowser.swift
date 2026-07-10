import AppKit
import SwiftUI

/// Shared Apple Music library browser used by the Transfer sheet and File Manager.
struct AppleMusicLibraryBrowser: View {
    enum Presentation {
        case sheet
        case fileManager
    }

    @EnvironmentObject private var model: AppModel

    var presentation: Presentation = .sheet
    var showsHeader: Bool = true
    var onDismiss: (() -> Void)?
    var onCopyToGarmin: (([URL]) -> Void)?
    var onSendToWatch: (([String]) -> Void)?
    var onAddToTransferQueue: (([String]) -> Void)?

    enum Category: String, CaseIterable, Identifiable {
        case playlists = "Playlists"
        case albums = "Albums"
        case allMusic = "All Music"
        var id: String { rawValue }
    }

    @State private var category: Category = .playlists
    @State private var selectedPlaylistID: String?
    @State private var selectedAlbumID: String?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var search = ""
    @State private var sortOrder: LibraryTrackSort = .titleAscending
    @State private var filters = LibraryTrackBrowserFilters()
    @State private var showingSortFilter = false

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            content
            Divider()
            footer
        }
        .onChange(of: category) { _, newValue in
            handleCategoryChange(newValue)
        }
        .onChange(of: selectedPlaylistID) { _, _ in
            if category == .playlists {
                selectAllImportable(in: baseTracks)
            }
        }
        .onChange(of: selectedAlbumID) { _, _ in
            if category == .albums {
                selectAllImportable(in: baseTracks)
            }
        }
        .onChange(of: model.musicLibraryStatus) { _, status in
            if case .loaded = status, category == .allMusic {
                selectAllImportable(in: baseTracks)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Apple Music Library", systemImage: "music.note.list")
                .font(presentation == .sheet ? .title2.bold() : .headline)
                .foregroundStyle(AppTheme.panelAccent(for: .mac))
                .lineLimit(1)
            Spacer()
            Button {
                model.loadAppleMusicLibrary()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            if presentation == .sheet {
                Button {
                    onDismiss?()
                    model.showAppleMusicBrowser = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(presentation == .sheet ? 16 : 10)
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

            HStack(spacing: 8) {
                TextField(searchPlaceholder, text: $search)
                    .textFieldStyle(.roundedBorder)

                Button {
                    showingSortFilter.toggle()
                } label: {
                    Label("Sort & Filter", systemImage: sortFilterSymbol)
                }
                .popover(isPresented: $showingSortFilter, arrowEdge: .bottom) {
                    sortFilterPopover
                }
            }
            .padding(.horizontal)

            if !filters.isDefault || sortOrder != .titleAscending {
                activeFilterBar
                    .padding(.horizontal)
            }

            if category == .allMusic {
                trackList
            } else {
                NavigationSplitView {
                    collectionList
                        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 280)
                } detail: {
                    trackList
                }
            }
        }
    }

    private var searchPlaceholder: String {
        switch category {
        case .playlists: return "Search playlists or tracks"
        case .albums: return "Search albums or tracks"
        case .allMusic: return "Search all music"
        }
    }

    private var sortFilterSymbol: String {
        filters.isDefault && sortOrder == .titleAscending
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
    }

    private var sortFilterPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sort & Filter")
                    .font(.headline)
                Spacer()
                Button("Reset") {
                    sortOrder = .titleAscending
                    filters = LibraryTrackBrowserFilters()
                }
                .disabled(filters.isDefault && sortOrder == .titleAscending)
            }
            .padding()

            Divider()

            Form {
                Section("Sort") {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(LibraryTrackSort.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }

                Section("Availability") {
                    Picker("Availability", selection: $filters.availability) {
                        ForEach(LibraryTrackAvailabilityFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }

                Section("Format") {
                    Picker("Format", selection: $filters.format) {
                        ForEach(LibraryTrackFormatFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }

                Section("Metadata") {
                    Picker("Metadata", selection: $filters.metadata) {
                        ForEach(LibraryTrackMetadataFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 280, idealWidth: 300, maxHeight: 460)
        }
    }

    private var activeFilterBar: some View {
        HStack(spacing: 6) {
            Text(sortOrder.rawValue)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.8), in: Capsule())

            ForEach(filters.activeLabels, id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.8), in: Capsule())
            }

            Spacer(minLength: 0)

            Button("Clear") {
                sortOrder = .titleAscending
                filters = LibraryTrackBrowserFilters()
            }
            .font(.caption)
            .buttonStyle(.borderless)
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
        case .allMusic:
            EmptyView()
        }
    }

    private var trackList: some View {
        let tracks = displayedTracks
        return Group {
            if category != .allMusic && baseTracks.isEmpty {
                Text("Select a \(category == .playlists ? "playlist" : "album") to view its tracks.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                Text(baseTracks.isEmpty ? "No tracks in this library." : "No tracks match the current search or filters.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    trackSelectionToolbar(for: tracks)
                    Divider()
                    List(tracks) { track in
                        trackRow(for: track)
                            .onDrag {
                                dragProvider(including: track)
                            }
                            .contextMenu {
                                trackContextMenu(for: track)
                            }
                    }
                }
            }
        }
    }

    private func trackSelectionToolbar(for tracks: [LibraryTrack]) -> some View {
        let importableIDs = Set(tracks.filter(\.isImportable).map(\.id))
        let selectedVisible = selectedTrackIDs.intersection(importableIDs)
        return HStack(spacing: 12) {
            Text("\(selectedVisible.count) of \(importableIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All") {
                selectedTrackIDs.formUnion(importableIDs)
            }
            .buttonStyle(.borderless)
            .disabled(importableIDs.isEmpty || selectedVisible.count == importableIDs.count)
            Button("Deselect All") {
                selectedTrackIDs.subtract(importableIDs)
            }
            .buttonStyle(.borderless)
            .disabled(selectedVisible.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func trackRow(for track: LibraryTrack) -> some View {
        let isSelected = selectedTrackIDs.contains(track.id)
        return Button {
            toggleTrackSelection(track)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    trackSelectionIcon(for: track, isSelected: isSelected)
                    trackText(for: track)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    importabilityBadge(for: track)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        trackSelectionIcon(for: track, isSelected: isSelected)
                        trackText(for: track)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    importabilityBadge(for: track)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!track.isImportable)
        .opacity(track.isImportable ? 1 : 0.75)
    }

    @ViewBuilder
    private var footer: some View {
        switch presentation {
        case .sheet:
            sheetFooter
        case .fileManager:
            fileManagerFooter
        }
    }

    private var sheetFooter: some View {
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
                    Button(queueActionTitle) {
                        performAddToQueue()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImportableCount == 0)
                }

                VStack(alignment: .trailing, spacing: 8) {
                    importSummaryText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(queueActionTitle) {
                        performAddToQueue()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImportableCount == 0)
                }
            }
        }
        .padding()
    }

    private var fileManagerFooter: some View {
        VStack(spacing: 8) {
            importSummaryText
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button("Copy to Garmin") {
                        performCopyToGarmin()
                    }
                    .disabled(selectedImportableCount == 0 || !model.deviceBrowser.isConfigured || model.isManagingDeviceFiles)

                    Button("Send to Watch") {
                        performSendToWatch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImportableCount == 0 || !model.destinationIsReady || model.isSyncing)

                    Button("Add to Queue") {
                        performAddToQueue()
                    }
                    .disabled(selectedImportableCount == 0)
                }

                VStack(alignment: .trailing, spacing: 8) {
                    Button("Copy to Garmin") {
                        performCopyToGarmin()
                    }
                    .disabled(selectedImportableCount == 0 || !model.deviceBrowser.isConfigured || model.isManagingDeviceFiles)
                    Button("Send to Watch") {
                        performSendToWatch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImportableCount == 0 || !model.destinationIsReady || model.isSyncing)
                    Button("Add to Queue") {
                        performAddToQueue()
                    }
                    .disabled(selectedImportableCount == 0)
                }
            }
        }
        .padding(10)
    }

    private func trackSelectionIcon(for track: LibraryTrack, isSelected: Bool) -> some View {
        Group {
            if track.isImportable {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.panelAccent(for: .mac) : .secondary)
            } else {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.orange)
            }
        }
        .font(.body)
        .frame(width: 20, alignment: .center)
    }

    private func trackText(for track: LibraryTrack) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
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

    private var filteredPlaylists: [LibraryPlaylist] {
        guard !search.isEmpty else { return model.musicLibrary.playlists }
        let query = search
        return model.musicLibrary.playlists.filter { playlist in
            if playlist.name.localizedCaseInsensitiveContains(query) { return true }
            return model.musicLibrary.tracks(for: playlist.trackIDs).contains { trackMatchesSearch($0, query: query) }
        }
    }

    private var filteredAlbums: [LibraryAlbum] {
        guard !search.isEmpty else { return model.musicLibrary.albums }
        let query = search
        return model.musicLibrary.albums.filter { album in
            if album.title.localizedCaseInsensitiveContains(query) { return true }
            if album.artist?.localizedCaseInsensitiveContains(query) == true { return true }
            return model.musicLibrary.tracks(for: album.trackIDs).contains { trackMatchesSearch($0, query: query) }
        }
    }

    private var baseTrackIDs: [String] {
        switch category {
        case .playlists:
            return model.musicLibrary.playlists.first { $0.id == selectedPlaylistID }?.trackIDs ?? []
        case .albums:
            return model.musicLibrary.albums.first { $0.id == selectedAlbumID }?.trackIDs ?? []
        case .allMusic:
            return Array(model.musicLibrary.tracksByID.keys)
        }
    }

    private var baseTracks: [LibraryTrack] {
        model.musicLibrary.tracks(for: baseTrackIDs)
    }

    private var displayedTracks: [LibraryTrack] {
        var tracks = baseTracks
        if !search.isEmpty {
            let query = search
            tracks = tracks.filter { trackMatchesSearch($0, query: query) }
        }
        tracks = tracks.filter(filters.matches)
        return tracks.sorted(by: sortOrder)
    }

    private var selectedImportableIDs: [String] {
        let allowed = Set(baseTracks.filter(\.isImportable).map(\.id))
        return baseTrackIDs.filter { selectedTrackIDs.contains($0) && allowed.contains($0) }
    }

    private var selectedImportableCount: Int { selectedImportableIDs.count }

    private var importableInCollectionCount: Int {
        baseTracks.filter(\.isImportable).count
    }

    private var importSummary: String {
        let total = baseTracks.count
        guard total > 0 else { return "No selection" }
        if selectedImportableCount == 0 {
            return "\(importableInCollectionCount) of \(total) tracks importable — none selected"
        }
        return "\(selectedImportableCount) of \(importableInCollectionCount) importable tracks selected"
    }

    private var queueActionTitle: String {
        if selectedImportableCount == 0 {
            return "Add to Transfer queue"
        }
        return "Add \(selectedImportableCount) to Transfer queue"
    }

    private var selectedImportableURLs: [URL] {
        model.musicLibrary.importableURLs(for: selectedImportableIDs)
    }

    private func trackMatchesSearch(_ track: LibraryTrack, query: String) -> Bool {
        track.title.localizedCaseInsensitiveContains(query)
            || (track.artist?.localizedCaseInsensitiveContains(query) ?? false)
            || (track.album?.localizedCaseInsensitiveContains(query) ?? false)
            || (track.fileExtension?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func toggleTrackSelection(_ track: LibraryTrack) {
        guard track.isImportable else { return }
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
        } else {
            selectedTrackIDs.insert(track.id)
        }
    }

    private func selectAllImportable(in tracks: [LibraryTrack]) {
        selectedTrackIDs = Set(tracks.filter(\.isImportable).map(\.id))
    }

    private func handleCategoryChange(_ newValue: Category) {
        selectedTrackIDs.removeAll()
        switch newValue {
        case .playlists:
            if selectedPlaylistID == nil {
                selectedPlaylistID = filteredPlaylists.first?.id
            }
            selectAllImportable(in: baseTracks)
        case .albums:
            if selectedAlbumID == nil {
                selectedAlbumID = filteredAlbums.first?.id
            }
            selectAllImportable(in: baseTracks)
        case .allMusic:
            selectAllImportable(in: baseTracks)
        }
    }

    private func prepareSelection(for track: LibraryTrack) {
        guard track.isImportable else { return }
        if !selectedTrackIDs.contains(track.id) {
            selectedTrackIDs = [track.id]
        }
    }

    private func dragProvider(including track: LibraryTrack) -> NSItemProvider {
        prepareSelection(for: track)
        return MultiFileDragPayload.itemProvider(for: selectedImportableURLs)
    }

    @ViewBuilder
    private func trackContextMenu(for track: LibraryTrack) -> some View {
        if track.isImportable {
            Button {
                prepareSelection(for: track)
                performCopyToGarmin()
            } label: {
                Label("Copy to Garmin", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.deviceBrowser.isConfigured || model.isManagingDeviceFiles)

            Button {
                prepareSelection(for: track)
                performSendToWatch()
            } label: {
                Label("Send to Watch", systemImage: "arrow.down.circle")
            }
            .disabled(!model.destinationIsReady || model.isSyncing)

            Button {
                prepareSelection(for: track)
                performAddToQueue()
            } label: {
                Label("Add to Transfer queue", systemImage: "tray.and.arrow.down")
            }
        }
    }

    private func performAddToQueue() {
        let trackIDs = selectedImportableIDs
        guard !trackIDs.isEmpty else { return }
        if let onAddToTransferQueue {
            onAddToTransferQueue(trackIDs)
            return
        }
        // Default sheet behavior (playlist-aware).
        if category == .playlists,
           let selectedPlaylistID,
           let playlist = model.musicLibrary.playlists.first(where: { $0.id == selectedPlaylistID }) {
            let allImportable = Set(model.musicLibrary.tracks(for: playlist.trackIDs).filter(\.isImportable).map(\.id))
            if Set(trackIDs) == allImportable {
                model.prepareAppleMusicPlaylistForSync(selectedPlaylistID)
                return
            }
        }
        model.importLibraryTracks(trackIDs)
    }

    private func performCopyToGarmin() {
        let urls = selectedImportableURLs
        guard !urls.isEmpty else { return }
        if let onCopyToGarmin {
            onCopyToGarmin(urls)
        } else {
            model.uploadFilesToDevice(urls)
        }
    }

    private func performSendToWatch() {
        let trackIDs = selectedImportableIDs
        guard !trackIDs.isEmpty else { return }
        if let onSendToWatch {
            onSendToWatch(trackIDs)
            return
        }
        let urls = selectedImportableURLs
        Task {
            await model.addFiles(urls)
            model.beginSend()
        }
    }
}
