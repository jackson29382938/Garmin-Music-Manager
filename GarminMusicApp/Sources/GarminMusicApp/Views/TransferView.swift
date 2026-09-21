import SwiftCrossUI
import GarminMusicCore

struct TransferView: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Transfer")
                    .font(.system(size: 22))
                Text("Copies the tracks you selected in Library into a destination folder — a mounted Garmin volume or any folder — and writes a playlist.")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)

                LabeledField(
                    caption: "Destination folder (Garmin volume or any folder)",
                    placeholder: "/Volumes/GARMIN/Music",
                    text: state.$destinationFolder
                )

                LabeledField(
                    caption: "Playlist name",
                    placeholder: "Garmin Playlist",
                    text: state.$playlistName
                )

                SegmentedPicker(
                    title: "Organization",
                    options: OrganizationChoice.allCases.map(\.rawValue),
                    selected: state.organization.rawValue
                ) { raw in
                    if let choice = OrganizationChoice(rawValue: raw) {
                        state.organization = choice
                    }
                }

                SegmentedPicker(
                    title: "When a file already exists",
                    options: OverwriteChoice.allCases.map(\.rawValue),
                    selected: state.overwrite.rawValue
                ) { raw in
                    if let choice = OverwriteChoice(rawValue: raw) {
                        state.overwrite = choice
                    }
                }

                Toggle("Write .m3u8 playlist after sending", isOn: state.$writePlaylist)
                    .toggleStyle(.switch)

                summaryCard

                HStack(spacing: 10) {
                    Button(state.isSending ? "Sending…" : "Send to Watch") {
                        state.send()
                    }
                    .disabled(!state.canSend)
                    Button("Refresh destination") {
                        state.refreshOnWatch()
                    }
                    Spacer()
                }

                if state.isSending || state.progress > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressBar(fraction: state.progress)
                        Text("\(Int(state.progress * 100))%")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(16)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to send")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Text("\(state.selectedTracks.count) track(s) · \(formatBytes(state.selectedBytes))")
                    .font(.system(size: 16))
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text("Blocked in selection")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Text("\(blockedSelected)")
                    .font(.system(size: 16))
                    .foregroundColor(blockedSelected > 0 ? .orange : .green)
            }
        }
        .padding(14)
        .background(Theme.card)
        .cornerRadius(12)
    }

    private var blockedSelected: Int {
        state.selectedTracks.filter { $0.compatibility.status == .blocked }.count
    }
}
