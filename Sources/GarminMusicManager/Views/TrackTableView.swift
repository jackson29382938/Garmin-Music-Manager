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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tracks")
                    .font(.headline)
                Text("\(model.syncableTracks.count) selected / \(model.tracks.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.blockedTracks.isEmpty {
                    Text("\(model.blockedTracks.count) blocked")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 10)

            if model.tracks.isEmpty {
                dropZone
            } else {
                List {
                    ForEach(displayedTrackIndices, id: \.self) { index in
                        TrackRowView(track: $model.tracks[index])
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
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Add music files")
                .font(.title3.bold())
            Text("Drag and drop MP3/AAC/M4A/WAV files here, or use Add Files / Add Folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                .padding()
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            model.handleDroppedURLs(urls)
        }
        return true
    }
}

struct TrackRowView: View {
    @Binding var track: AudioTrack
    @State private var availableWidth: CGFloat = 0

    /// Below this width the trailing status column does not have room, so the
    /// row reflows into a vertical layout instead of clipping content.
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

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)
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
