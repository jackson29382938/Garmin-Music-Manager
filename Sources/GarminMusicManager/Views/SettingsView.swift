import GarminMusicCore
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

            Section("Garmin Browser") {
                Toggle("Enable advanced full-storage explorer", isOn: $model.advancedStorageExplorerEnabled)

                Picker("Destructive confirmation", selection: $model.destructiveConfirmationMode) {
                    ForEach(DestructiveConfirmationMode.allCases) { mode in
                        Text(label(for: mode)).tag(mode)
                    }
                }

                if !model.advancedStorageExplorerEnabled {
                    Text("The Garmin browser stays music-focused by default. Full storage is hidden until this setting is enabled.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("MTP Backend") {
                Label(model.mtpDependencyStatus.message, systemImage: model.mtpDependencyStatus.isReady ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.mtpDependencyStatus.isReady ? .green : .orange)
                Text("The app uses the bundled Garmin helper for MTP browsing and file operations. Homebrew/libmtp is only installed when you choose Install MTP Support.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Save Settings") {
                    model.saveSettings()
                }
            }

            Section("About") {
                Text("Garmin Music Manager copies local audio to mounted Garmin folders and helper-backed Garmin MTP devices. Streaming-provider files may stay hidden or protected on the watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }

    private func label(for mode: DestructiveConfirmationMode) -> String {
        switch mode {
        case .always:
            return "Always"
        case .batchesOnly:
            return "Batches only"
        case .never:
            return "Never"
        }
    }
}
