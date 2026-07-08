import SwiftUI
import UniformTypeIdentifiers

struct TrackTableView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false

    private var displayedTrackIndices: [Int] {
        if model.searchText.isEmpty {
            return Array(model.tracks.indices)
        }
        let filteredIDs = Set(model.filteredTracks.map(\.id))
        return model.tracks.indices.filter { filteredIDs.contains(model.tracks[$0].id) }
    }

    private var headerChips: [String] {
        var chips = ["\(model.syncableTracks.count) selected", "\(model.tracks.count) total"]
        if !model.blockedTracks.isEmpty {
            chips.append("\(model.blockedTracks.count) blocked")
        }
        if model.duplicateTrackCount > 0 {
            chips.append("\(model.duplicateTrackCount) on device")
        }
        return chips
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                side: .mac,
                title: "Mac Library",
                subtitle: model.macLibraryLocationDescription,
                systemImage: "laptopcomputer",
                chips: headerChips
            )

            if model.tracks.isEmpty {
                dropZone
            } else if displayedTrackIndices.isEmpty {
                noResultsView
            } else {
                List {
                    ForEach(displayedTrackIndices, id: \.self) { index in
                        TrackRowView(track: $model.tracks[index])
                            .onDrag {
                                trackDragProvider(for: model.tracks[index])
                            }
                            .help("Drag to Garmin Library below")
                    }
                    .onDelete { offsets in
                        model.removeTracks(at: offsets)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers)
                }
            }
        }
        .background(AppTheme.panelBackground(for: .mac).opacity(0.5))
    }

    private var dropZone: some View {
        ViewThatFits(in: .vertical) {
            fullDropZoneContent
            compactDropZoneContent
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? AppTheme.macTint.opacity(0.12) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.panelCornerRadius, style: .continuous)
                .strokeBorder(
                    isTargeted ? AppTheme.macTint : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [8, 6])
                )
                .padding(16)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var fullDropZoneContent: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.panelAccent(for: .mac).opacity(0.6))

            VStack(spacing: 6) {
                Text("Add music from your Mac")
                    .font(.title3.bold())
                Text("Files stay here until you sync. Drop audio files or use the buttons below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            addMusicControls
        }
    }

    private var compactDropZoneContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(AppTheme.panelAccent(for: .mac).opacity(0.7))

            VStack(alignment: .leading, spacing: 3) {
                Text("Add music from your Mac")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text("Drop audio files here or use the add buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            addMusicControls
        }
    }

    private var addMusicControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                addFilesButton
                addFolderButton
            }

            VStack(spacing: 8) {
                addFilesButton
                addFolderButton
            }
        }
        .controlSize(.regular)
        .buttonStyle(.bordered)
    }

    private var addFilesButton: some View {
        Button {
            model.chooseMusicFiles()
        } label: {
            Label("Add Files", systemImage: "plus")
        }
    }

    private var addFolderButton: some View {
        Button {
            model.chooseMusicFolder()
        } label: {
            Label("Add Folder", systemImage: "folder.badge.plus")
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No matching tracks")
                .font(.title3.bold())
            Text("Try a different search term.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Clear Search") {
                model.searchText = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            model.handleDroppedURLs(urls)
        }
        return true
    }

    private func trackDragProvider(for track: AudioTrack) -> NSItemProvider {
        NSItemProvider(contentsOf: track.url)
            ?? NSItemProvider(object: track.url.absoluteString as NSString)
    }
}

struct TrackRowView: View {
    @Binding var track: AudioTrack
    @State private var availableWidth: CGFloat = 0

    private let wideThreshold: CGFloat = 460

    var body: some View {
        Group {
            if availableWidth > 0, availableWidth < wideThreshold {
                compactRow
            } else {
                wideRow
            }
        }
        .padding(.vertical, 4)
        .background(widthReader)
    }

    private var wideRow: some View {
        HStack(spacing: 12) {
            leadingControls
            trackInfo
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.compatibility.summary)
                .font(.caption)
                .foregroundStyle(statusTint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(width: 200, alignment: .trailing)
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                leadingControls
                trackInfo
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            Text(track.compatibility.summary)
                .font(.caption)
                .foregroundStyle(statusTint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var leadingControls: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $track.isSelected)
                .labelsHidden()
                .disabled(!track.compatibility.canCopy)
                .accessibilityLabel("Select \(track.displayName)")

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)
                .accessibilityLabel(track.compatibility.status.rawValue)
        }
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(track.displayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if track.isDuplicateOnDevice {
                    Text("On device")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2))
                        .clipShape(Capsule())
                        .layoutPriority(1)
                }
            }
            Text(metadataText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var widthReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { availableWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, newWidth in
                    availableWidth = newWidth
                }
        }
    }

    private var metadataText: String {
        var parts = [track.fileName, track.sizeDescription, track.durationDescription]
        if let codec = track.codecHint { parts.append(codec) }
        return parts.joined(separator: " • ")
    }

    private var statusTint: Color {
        track.compatibility.status == .blocked ? .red : .secondary
    }

    private var iconName: String {
        switch track.compatibility.status {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch track.compatibility.status {
        case .ready: return .green
        case .warning: return .orange
        case .blocked: return .red
        }
    }
}
