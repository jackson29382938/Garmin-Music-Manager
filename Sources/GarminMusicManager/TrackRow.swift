import SwiftUI

struct TrackRow: View {
    @Binding var track: MusicTrack
    let repairAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $track.isSelected)
                .labelsHidden()
                .disabled(track.status == .unsupported && track.workingURL == nil)

            Image(systemName: track.status.symbolName)
                .foregroundStyle(track.status.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(track.displayTitle)
                        .font(.headline)
                    if track.workingURL != nil {
                        Label("generated copy", systemImage: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Text(track.sourceURLForSync.pathExtension.uppercased())
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }

                Text(track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !track.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(track.issues) { issue in
                            Label(issue.message, systemImage: issue.severity.symbolName)
                                .font(.caption)
                                .foregroundStyle(issue.severity.tint)
                        }
                    }
                }

                HStack {
                    Text(track.sourceURLForSync.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Repair Metadata") { repairAction() }
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MetadataRepairSheet: View {
    let track: MusicTrack
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Repair Metadata")
                    .font(.title2.bold())
                Text(track.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Form {
                TextField("Title", text: $model.metadataDraft.title)
                TextField("Artist", text: $model.metadataDraft.artist)
                TextField("Album", text: $model.metadataDraft.album)
                TextField("Track number", text: $model.metadataDraft.trackNumber)
            }

            Text("When ffmpeg is installed, the app writes a repaired copy in its cache and syncs that copy instead of modifying your original file.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { model.cancelMetadataRepair() }
                Button("Apply Repair") { model.applyMetadataRepair() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
