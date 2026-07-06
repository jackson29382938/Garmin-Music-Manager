import GarminMusicCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AppLogoMark(size: 30)
                Text("Garmin Music Manager")
                    .font(.title2.bold())
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Devices")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        model.refreshDevices()
                    }
                    .help("Refresh devices and library")
                }

                if model.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.connectedUSBDevices.isEmpty {
                            Text("No visible Garmin device found.")
                                .font(.subheadline)
                            Text("macOS is not reporting a mounted Garmin volume or a Garmin USB device. Check that the cable supports data, the watch is unlocked/awake, and USB mode is enabled on the watch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Garmin connected over USB", systemImage: "cable.connector")
                                .font(.subheadline)
                            ForEach(model.connectedUSBDevices) { device in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.displayName)
                                        .font(.caption.bold())
                                    if model.isMTPLibraryLoaded || !model.deviceBrowser.files.isEmpty {
                                        Label("Music library loaded", systemImage: "music.note.list")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("Ready for MTP sync and library browsing.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if model.mtpDependencyStatus.isReady {
                                Label("MTP support ready", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Button {
                                    model.browseGarminMusicLibrary()
                                } label: {
                                    HStack(spacing: 6) {
                                        if model.deviceBrowser.isRefreshing {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        Text(model.deviceBrowser.isRefreshing ? "Loading Garmin Library..." : "Show Garmin Music Library")
                                    }
                                }
                                .disabled(model.deviceBrowser.isRefreshing)
                            } else {
                                Text(model.mtpDependencyStatus.message)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Button(model.isInstallingMTPDependencies ? "Installing MTP Support…" : "Install MTP Support") {
                                    model.installMTPDependencies()
                                }
                                .disabled(model.isInstallingMTPDependencies)
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    List(selection: Binding(
                        get: { model.selectedDevice },
                        set: { device in
                            if let device { model.selectDevice(device) }
                        }
                    )) {
                        ForEach(model.devices) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.volumeName)
                                    .font(.headline)
                                Text(device.storageDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(device.bestMusicDirectory?.path ?? device.rootURL.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .tag(Optional(device))
                        }
                    }
                    .frame(minHeight: 140)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Destination")
                    .font(.headline)
                Text(model.destinationDescription)
                    .font(.caption)
                    .foregroundStyle(model.destinationIsReady ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                if model.isMTPLibraryMode {
                    Text("Synced over MTP — macOS does not mount the watch as a Finder folder.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !model.isMTPLibraryMode {
                    Button("Choose Music Folder") {
                        model.chooseDestinationFolder()
                    }
                }
            }

            if let storage = model.deviceBrowser.storageInfo {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Storage")
                        .font(.headline)

                    ProgressView(value: storageProgress(for: storage))
                        .tint(model.exceedsAvailableStorage ? .red : .accentColor)
                        .accessibilityLabel("Storage usage")
                        .accessibilityValue("\(Int(storageProgress(for: storage) * 100))% used")

                    Text("\(availableDescription(for: storage)) free of \(totalDescription(for: storage))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(storage.fileCount) files (\(ByteCountFormatter.string(fromByteCount: storage.usedByFiles, countStyle: .file)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if model.exceedsAvailableStorage {
                        Label("Selected tracks exceed free space", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Label("Local/owned files only", systemImage: "checkmark.shield")
                Label("No DRM removal", systemImage: "lock")
                Label("MTP sync supported", systemImage: "cable.connector")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func availableDescription(for storage: DeviceStorageInfo) -> String {
        guard let available = storage.availableCapacity else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
    }

    private func totalDescription(for storage: DeviceStorageInfo) -> String {
        guard let total = storage.totalCapacity else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func storageProgress(for storage: DeviceStorageInfo) -> Double {
        guard let total = storage.totalCapacity, total > 0 else { return 0 }
        let used = total - (storage.availableCapacity ?? total)
        return Double(used) / Double(total)
    }
}
