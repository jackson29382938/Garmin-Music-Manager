import SwiftCrossUI
import GarminMusicCore

struct LibraryView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library")
                .font(.system(size: 22))
            Text("Point at a folder of music. Files are checked for Garmin compatibility using the shared engine.")
                .font(.system(size: 12))
                .foregroundColor(.gray)

            LabeledField(
                caption: "Music folder",
                placeholder: "/path/to/your/music",
                text: state.$sourceFolder
            )

            HStack(spacing: 8) {
                Button(state.isScanning ? "Scanning…" : "Scan folder") {
                    state.scan()
                }
                Button("Select ready") {
                    state.selectAllCopyable()
                }
                Button("Clear") {
                    state.clearSelection()
                }
                Spacer()
                Text("\(state.selectedTracks.count) selected · \(formatBytes(state.selectedBytes))")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            HStack(spacing: 10) {
                StatChip(value: "\(state.tracks.count)", label: "Files", tint: Theme.accent)
                StatChip(value: "\(state.readyCount)", label: "Ready", tint: .green)
                StatChip(value: "\(state.warningCount)", label: "Warning", tint: .orange)
                StatChip(value: "\(state.blockedCount)", label: "Blocked", tint: .red)
                Spacer()
            }

            if state.tracks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(state.tracks) { track in
                            trackRow(track)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No music loaded yet")
                .font(.system(size: 15))
            Text("Enter a folder path above and choose Scan folder.")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.card)
        .cornerRadius(12)
    }

    private func trackRow(_ track: LibraryTrack) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { state.isSelected(track.id) },
                    set: { state.setSelected(track.id, $0) }
                )
            )
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.fileName)
                    .font(.system(size: 13))
                if !track.detail.isEmpty {
                    Text(track.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            Text(formatBytes(track.byteCount))
                .font(.system(size: 11))
                .foregroundColor(.gray)

            StatusBadge(
                text: track.statusText,
                color: Theme.statusColor(track.compatibility.status)
            )
        }
        .padding(10)
        .background(Theme.card)
        .cornerRadius(10)
    }
}
