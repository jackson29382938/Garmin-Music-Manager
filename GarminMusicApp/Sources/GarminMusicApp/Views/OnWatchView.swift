import SwiftCrossUI
import GarminMusicCore

struct OnWatchView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On Watch")
                .font(.system(size: 22))
            Text("Files currently in the destination folder.")
                .font(.system(size: 12))
                .foregroundColor(.gray)

            LabeledField(
                caption: "Destination folder",
                placeholder: "/Volumes/GARMIN/Music",
                text: state.$destinationFolder
            )

            HStack(spacing: 8) {
                Button("Refresh") {
                    state.refreshOnWatch()
                }
                Spacer()
                Text("\(state.onWatchFiles.count) item(s) · \(formatBytes(totalBytes))")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            if state.onWatchFiles.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing on the watch yet")
                        .font(.system(size: 15))
                    Text("Send some tracks from Transfer, then Refresh.")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Theme.card)
                .cornerRadius(12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.onWatchFiles) { file in
                            fileRow(file)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(16)
    }

    private var totalBytes: Int64 {
        state.onWatchFiles.reduce(0) { $0 + $1.byteCount }
    }

    private func fileRow(_ file: WatchFile) -> some View {
        HStack(spacing: 10) {
            Text(file.isAudio ? "♪" : "•")
                .font(.system(size: 13))
                .foregroundColor(file.isAudio ? Theme.accent : .gray)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 13))
                Text(file.relativePath)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()
            Text(formatBytes(file.byteCount))
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .padding(10)
        .background(Theme.card)
        .cornerRadius(10)
    }
}
