import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Sync") {
                Picker("Overwrite policy", selection: $model.syncSettings.overwritePolicy) {
                    ForEach(OverwritePolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }

                Picker("Organization", selection: $model.syncSettings.organizationPolicy) {
                    ForEach(OrganizationPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }

                Toggle("Write M3U8 playlist", isOn: $model.syncSettings.writePlaylist)
                Text("M3U8 playlists are only written when syncing to a mounted folder. Garmin watches synced over USB/MTP reject non-audio files, so playlists are managed in Garmin Connect instead.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Defaults") {
                TextField("Default playlist name", text: $model.playlistName)
            }

            Section {
                Button("Save Settings") {
                    model.saveSettings()
                }
            }

            Section("About") {
                Text("Garmin Music Manager copies local audio to a mounted Garmin music folder. Watches that only expose MTP storage must be mounted or exposed by another tool first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
