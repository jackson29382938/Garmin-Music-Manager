import GarminMusicCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
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

                Toggle("Convert ALAC/FLAC to AAC (requires ffmpeg)", isOn: $model.syncSettings.convertIncompatibleFormats)

                Toggle("Write M3U8 playlist", isOn: $model.syncSettings.writePlaylist)
                Text("M3U8 playlists are only written when syncing to a mounted folder. Garmin watches synced over USB/MTP reject non-audio files, so playlists are managed in Garmin Connect instead.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }

            Section {
                TextField("Default playlist name", text: $model.playlistName)
            } header: {
                Label("Defaults", systemImage: "textformat")
            }

            Section {
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
            } header: {
                Label("Garmin Browser", systemImage: "applewatch")
            }

            Section {
                Label(model.mtpDependencyStatus.message, systemImage: model.mtpDependencyStatus.isReady ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.mtpDependencyStatus.isReady ? .green : .orange)
                Text("The app uses the bundled Garmin helper for MTP browsing and file operations. Homebrew/libmtp is only installed when you choose Install MTP Support.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("MTP Backend", systemImage: "cable.connector")
            }

            Section {
                Button("Save Settings") {
                    model.saveSettings()
                }
            }

            Section {
                Button(role: .destructive) {
                    model.requestResetAppState()
                } label: {
                    Label("Clear Cache / Reset App", systemImage: "arrow.counterclockwise")
                }

                Text("Clears app selections, cached library data, logs, and temporary conversions without deleting music files.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }

            Section {
                Label("Local/owned files only", systemImage: "checkmark.shield")
                Label("No DRM removal", systemImage: "lock")
                Label("MTP sync supported", systemImage: "cable.connector")
                Text("Garmin Music Manager copies local audio to mounted Garmin folders and helper-backed Garmin MTP devices. Streaming-provider files may stay hidden or protected on the watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .alert("Reset app state?", isPresented: $model.showResetConfirmation) {
            Button("Reset", role: .destructive) {
                model.resetAppState()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears app selections, cached library data, logs, and temporary conversions. It does not delete music files from this Mac or the Garmin.")
        }
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
