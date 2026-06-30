import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            VStack(spacing: 0) {
                HeaderView()
                Divider()
                VSplitView {
                    VStack(spacing: 0) {
                        TrackTableView()
                        Divider()
                        LibraryTransferBridge()
                    }
                    .frame(minHeight: 220)
                    DeviceContentsView()
                        .frame(minHeight: 320)
                }
                Divider()
                TransferPanelView()
            }
            .toolbar {
                PrimaryActionsToolbar(model: model)
            }
        }
        .sheet(isPresented: $model.showSyncPreview) {
            SyncPreviewSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showAppleMusicBrowser) {
            AppleMusicBrowserView()
                .environmentObject(model)
        }
        .alert("Delete selected files?", isPresented: $model.showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.deleteSelectedDeviceFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected audio files from the Garmin or selected destination folder.")
        }
    }
}

private struct LibraryTransferBridge: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Label("Mac Library", systemImage: "laptopcomputer")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Image(systemName: "arrow.down")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Label("Garmin Library", systemImage: "applewatch")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(model.syncableTracks.count) ready")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.uploadSelectedTracksToDevice()
            } label: {
                Label("Send Selected", systemImage: "arrow.down.to.line.compact")
            }
            .disabled(!model.canUploadSelectedTracksToDevice)
            .controlSize(.small)

            Button {
                model.copySelectedDeviceFilesToMac()
            } label: {
                Label("Copy to Mac", systemImage: "arrow.up.to.line.compact")
            }
            .disabled(model.deviceBrowser.selectedFileIDs.isEmpty || model.isManagingDeviceFiles)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
