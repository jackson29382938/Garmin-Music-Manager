import SwiftCrossUI
import GarminMusicCore

struct SettingsView: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings")
                    .font(.system(size: 22))

                sectionTitle("Defaults")
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
                    title: "Overwrite policy",
                    options: OverwriteChoice.allCases.map(\.rawValue),
                    selected: state.overwrite.rawValue
                ) { raw in
                    if let choice = OverwriteChoice(rawValue: raw) {
                        state.overwrite = choice
                    }
                }
                Toggle("Write .m3u8 playlist after sending", isOn: state.$writePlaylist)
                    .toggleStyle(.switch)

                sectionTitle("Supported formats")
                infoCard(
                    "Garmin music watches play MP3, M4A/AAC and WAV. FLAC, ALAC, OGG, "
                        + "WMA and DRM-protected files are flagged as not compatible. The Library "
                        + "tab shows each file's status before you send."
                )

                sectionTitle("About")
                infoCard(
                    "This is the cross-platform edition of Garmin Music Manager, written in "
                        + "Swift with SwiftCrossUI. The same code runs natively on Windows (WinUI), "
                        + "macOS (AppKit) and Linux (Gtk), and shares the GarminMusicCore engine "
                        + "with the native macOS app."
                )
            }
            .padding(16)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(.gray)
            .padding(.top, 4)
    }

    private func infoCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Theme.card)
            .cornerRadius(12)
    }
}
