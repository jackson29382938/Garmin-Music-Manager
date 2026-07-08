import GarminMusicCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    AppLogoMark(size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Garmin Music")
                            .font(.title3.bold())
                            .lineLimit(1)
                        Text("Manager")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                watchCard
                destinationCard

                if let storage = model.deviceBrowser.storageInfo {
                    storageCard(storage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var watchCard: some View {
        StatusCard(
            title: "Your Watch",
            systemImage: "applewatch",
            status: watchStatus,
            message: watchMessage
        ) {
            watchActions

            if !model.devices.isEmpty {
                deviceList
            }
        }
    }

    private var watchActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                refreshButton
                showLibraryButton
                installMTPButton
            }

            VStack(alignment: .leading, spacing: 8) {
                refreshButton
                showLibraryButton
                installMTPButton
            }
        }
        .controlSize(.small)
    }

    private var refreshButton: some View {
        Button("Refresh") {
            model.refreshDevices()
        }
        .keyboardShortcut("r", modifiers: .command)
    }

    @ViewBuilder
    private var showLibraryButton: some View {
        if model.connectedUSBDevices.isEmpty == false, model.mtpDependencyStatus.isReady {
            Button {
                model.browseGarminMusicLibrary()
            } label: {
                if model.deviceBrowser.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Show Library")
                }
            }
            .disabled(model.deviceBrowser.isRefreshing)
        }
    }

    @ViewBuilder
    private var installMTPButton: some View {
        if model.connectedUSBDevices.isEmpty == false, !model.mtpDependencyStatus.isReady {
            Button(model.isInstallingMTPDependencies ? "Installing…" : "Install MTP") {
                model.installMTPDependencies()
            }
            .disabled(model.isInstallingMTPDependencies)
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        List(selection: Binding(
            get: { model.selectedDevice },
            set: { device in
                if let device { model.selectDevice(device) }
            }
        )) {
            ForEach(model.devices) { device in
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.volumeName)
                        .font(.caption.bold())
                    Text(device.storageDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .tag(Optional(device))
            }
        }
        .frame(minHeight: 80, maxHeight: 120)
    }

    private var destinationCard: some View {
        StatusCard(
            title: "Sync Destination",
            systemImage: "folder",
            status: model.destinationIsReady ? .ready : .error,
            message: model.destinationDescription
        ) {
            Picker("Mode", selection: Binding(
                get: { model.destinationMode },
                set: { mode in
                    if mode == .autoDetected {
                        model.useAutoDetectedDestination()
                    } else if model.destinationMode != .customFolder {
                        model.chooseCustomGarminFolder()
                    }
                }
            )) {
                Text("Auto").tag(GarminDestinationMode.autoDetected)
                Text("Custom").tag(GarminDestinationMode.customFolder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.destinationMode == .customFolder {
                Button("Choose Folder…") {
                    model.chooseCustomGarminFolder()
                }
                .controlSize(.small)
            }

            if model.isMTPLibraryMode {
                Label("Synced over USB/MTP — not a Finder volume", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warning = model.destinationWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func storageCard(_ storage: DeviceStorageInfo) -> some View {
        StatusCard(
            title: "Watch Storage",
            systemImage: "internaldrive",
            status: model.exceedsAvailableStorage ? .warning : .ready,
            message: "\(availableDescription(for: storage)) free · \(storage.fileCount) files"
        ) {
            if let total = storage.totalCapacity, let available = storage.availableCapacity, total > 0 {
                let used = max(0, total - available)
                ProgressView(value: Double(used), total: Double(total))
                    .tint(model.exceedsAvailableStorage ? .orange : AppTheme.garminTint)
            }

            if model.exceedsAvailableStorage {
                Label("Selection exceeds free space", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var watchStatus: ConnectionStatus {
        if model.destinationIsReady { return .ready }
        if !model.connectedUSBDevices.isEmpty { return .warning }
        return .error
    }

    private var watchMessage: String {
        if !model.devices.isEmpty {
            return "\(model.devices.count) mounted volume(s) found."
        }
        if let device = model.connectedUSBDevices.first {
            if model.mtpDependencyStatus.isReady {
                return "\(device.displayName) connected over USB. Ready for MTP sync."
            }
            return "\(device.displayName) detected. Install MTP support to sync."
        }
        return "No Garmin found. Connect via USB, unlock the watch, and refresh."
    }

    private func availableDescription(for storage: DeviceStorageInfo) -> String {
        guard let available = storage.availableCapacity else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
    }
}
