import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            VStack(spacing: 0) {
                WorkflowGuideView(steps: model.workflowSteps)
                Divider()
                HeaderView()
                Divider()
                VSplitView {
                    TrackTableView()
                        .frame(minHeight: 110)
                    LibraryFlowConnector()
                    DeviceContentsView()
                        .frame(minHeight: 140)
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
        .sheet(isPresented: $model.showMoveWithinGarminSheet) {
            MoveWithinGarminSheet()
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
        .alert("Delete original files?", isPresented: $model.showMTPMoveDeleteConfirmation) {
            Button("Delete Originals", role: .destructive) {
                model.confirmDeleteOriginalsAfterMTPMove()
            }
            Button("Keep Originals", role: .cancel) {
                model.cancelDeleteOriginalsAfterMTPMove()
            }
        } message: {
            Text("The files were copied to the new Garmin folder. Delete the original copies to complete the move.")
        }
    }
}

struct LibraryFlowConnector: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullConnector
            compactConnector
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var fullConnector: some View {
        HStack(spacing: 16) {
            Label("Mac", systemImage: "laptopcomputer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.panelAccent(for: .mac))

            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.panelAccent(for: .garmin))

            Label("Garmin", systemImage: "applewatch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.panelAccent(for: .garmin))

            Spacer()

            if let reason = model.uploadDisabledReason, !model.canUploadSelectedTracksToDevice {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .trailing)
            }

            sendSelectedButton
            copyToMacButton
        }
    }

    private var compactConnector: some View {
        HStack(spacing: 10) {
            Label("Mac to Garmin", systemImage: "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.panelAccent(for: .garmin))
                .lineLimit(1)

            if let reason = model.uploadDisabledReason, !model.canUploadSelectedTracksToDevice {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            Menu {
                sendSelectedButton
                copyToMacButton
            } label: {
                Label("Transfer", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
        }
    }

    private var sendSelectedButton: some View {
        Button {
            model.uploadSelectedTracksToDevice()
        } label: {
            Label("Send Selected to Garmin", systemImage: "arrow.down.to.line.compact")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(!model.canUploadSelectedTracksToDevice)
        .help("Quick-send selected Mac tracks using your current sync settings")
    }

    private var copyToMacButton: some View {
        Button {
            model.copySelectedDeviceFilesToMac()
        } label: {
            Label("Copy to Mac", systemImage: "arrow.up.to.line.compact")
        }
        .controlSize(.regular)
        .disabled(model.deviceBrowser.selectedFileIDs.isEmpty || model.isManagingDeviceFiles)
        .help("Copy selected Garmin files to a folder on this Mac")
    }
}

private struct MoveWithinGarminSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var targetPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Move Within Garmin", systemImage: "folder")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.panelAccent(for: .garmin))

            Text("Choose a folder on the watch. Files are copied first; originals can be deleted after.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Folder", selection: $targetPath) {
                ForEach(model.suggestedGarminMoveTargetPaths, id: \.self) { path in
                    Text(path).tag(path)
                }
            }
            .pickerStyle(.menu)

            TextField("Garmin folder path", text: $targetPath)
                .textFieldStyle(.roundedBorder)

            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer()
                    cancelButton
                    moveButton
                }

                VStack(alignment: .trailing, spacing: 8) {
                    cancelButton
                    moveButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            targetPath = model.moveTargetPath
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            dismiss()
            model.showMoveWithinGarminSheet = false
        }
    }

    private var moveButton: some View {
        Button("Move") {
            dismiss()
            model.moveSelectedWithinGarmin(to: targetPath)
        }
        .buttonStyle(.borderedProminent)
        .disabled(targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
