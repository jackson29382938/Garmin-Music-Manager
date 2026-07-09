import SwiftUI

/// Device file manager mode — browse, delete, and copy music already on the watch.
struct OnWatchView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.destinationIsReady && model.connectedUSBDevices.isEmpty {
                disconnectedState
            } else {
                DeviceContentsView(showsPanelHeader: false)
            }
        }
        .onAppear {
            ensureLibraryLoaded()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On your watch")
                    .font(.title2.bold())
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let storage = model.deviceBrowser.storageInfo,
               let free = storage.availableCapacity {
                StatChip(
                    text: "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free",
                    tint: AppTheme.garminTint
                )
            }
            recoveryActions
            Button {
                ensureLibraryLoaded(force: true)
            } label: {
                if model.deviceBrowser.isRefreshing || model.isBrowsingDevice {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.deviceBrowser.isRefreshing || model.isBrowsingDevice || model.isManagingDeviceFiles)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(AppTheme.panelBackground(for: .garmin))
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if !model.destinationIsReady {
            if !model.mtpDependencyStatus.isReady, model.mtpDependencyStatus.canInstallViaHomebrew {
                Button {
                    model.installMTPDependencies()
                } label: {
                    if model.isInstallingMTPDependencies {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Install MTP", systemImage: "cable.connector")
                    }
                }
                .disabled(model.isInstallingMTPDependencies)
                .controlSize(.small)
            }
            Button {
                model.chooseCustomGarminFolder()
            } label: {
                Label("Choose folder…", systemImage: "folder")
            }
            .controlSize(.small)
        }
    }

    private var headerSubtitle: String {
        if model.destinationIsReady {
            return model.garminLibraryLocationDescription
        }
        if !model.connectedUSBDevices.isEmpty {
            if !model.mtpDependencyStatus.isReady {
                return "Watch detected — install MTP or choose a music folder"
            }
            return "Watch detected — refresh to open the library"
        }
        return "Connect a Garmin to browse music on the device"
    }

    private var disconnectedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "applewatch.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No watch connected")
                .font(.title3.bold())
            Text("Plug in your Garmin, unlock it, then refresh. You can also choose a music folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) {
                Button("Refresh") {
                    model.refreshDevices()
                }
                .buttonStyle(.bordered)
                Button("Choose folder…") {
                    model.chooseCustomGarminFolder()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ensureLibraryLoaded(force: Bool = false) {
        model.refreshDevices()
        guard model.destinationIsReady || model.canAttemptMTP else { return }
        if force || !model.deviceBrowser.hasFreshListing {
            if model.canAttemptMTP || model.deviceBrowser.backendKind == .mtp {
                model.browseGarminMusicLibrary(force: force || !model.deviceBrowser.hasFreshListing)
            } else {
                model.refreshDeviceContents()
            }
        }
    }
}
