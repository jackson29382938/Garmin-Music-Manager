import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode: AppMode = .transfer

    private var showsStickyProgress: Bool {
        model.isSyncing || model.isManagingDeviceFiles
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            Divider()

            if showsStickyProgress {
                StickyTransferProgressBar()
                Divider()
            }

            if let notice = model.userNotice {
                UserNoticeBanner(
                    notice: notice,
                    onAction: { model.performNoticeAction() },
                    onDismiss: { model.dismissNotice() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            Group {
                switch mode {
                case .transfer:
                    TransferHomeView()
                case .onWatch:
                    OnWatchView()
                case .settings:
                    SettingsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if model.librarySettings.rememberLastAppMode,
               let saved = AppMode(rawValue: model.librarySettings.lastAppMode) {
                mode = saved
            }
        }
        .onChange(of: mode) { _, newMode in
            guard model.librarySettings.rememberLastAppMode else { return }
            var lib = model.librarySettings
            lib.lastAppMode = newMode.rawValue
            model.librarySettings = lib
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if mode == .transfer {
                    Button {
                        model.openAppleMusicBrowser()
                    } label: {
                        Label("Apple Music", systemImage: "music.note.list")
                    }
                    .help("Load and browse your Apple Music library")

                    Button {
                        model.beginSend()
                    } label: {
                        Label("Send to Watch", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.canSync)
                    .help("Send selected tracks to the Garmin")
                }

                if model.isSyncing {
                    Button(role: .destructive) {
                        model.cancelSync()
                    } label: {
                        Label("Cancel Transfer", systemImage: "xmark.circle")
                    }
                    .help("Cancel the in-progress transfer")
                } else if model.isManagingDeviceFiles || model.isBrowsingDevice {
                    Button(role: .destructive) {
                        model.cancelDeviceOperation()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .help("Cancel the in-progress device operation")
                }
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
        .onChange(of: mode) { _, newMode in
            if newMode == .onWatch {
                if model.canAttemptMTP && !model.deviceBrowser.isConfigured {
                    model.browseGarminMusicLibrary()
                }
            }
        }
        .onChange(of: model.shouldFocusOnWatch) { _, focus in
            guard focus else { return }
            mode = .onWatch
            model.consumeFocusOnWatch()
            if model.canAttemptMTP || model.destinationIsReady {
                if model.canAttemptMTP {
                    model.browseGarminMusicLibrary(force: false)
                } else {
                    model.refreshDeviceContents()
                }
            }
        }
        .onChange(of: model.shouldFocusTransfer) { _, focus in
            guard focus else { return }
            mode = .transfer
            model.consumeFocusTransfer()
        }
    }

    private var modePicker: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                AppLogoMark(size: 22)
                Text("Garmin Music")
                    .font(.headline)
                    .lineLimit(1)
            }

            Picker("Mode", selection: $mode) {
                ForEach(AppMode.allCases) { appMode in
                    Label(appMode.title, systemImage: appMode.systemImage)
                        .tag(appMode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            Spacer(minLength: 0)

            connectionPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var connectionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionPillColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(connectionPillText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .help(model.destinationDescription)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(connectionPillText)")
    }

    private var connectionPillColor: Color {
        if model.destinationIsReady { return .green }
        if !model.connectedUSBDevices.isEmpty { return .orange }
        return .secondary
    }

    private var connectionPillText: String {
        if model.isSyncing, let snapshot = model.transferProgress {
            return snapshot.itemLabel ?? "Sending \(snapshot.percentLabel)"
        }
        if model.destinationIsReady {
            return model.connectedMTPDeviceName
                ?? model.connectedUSBDevices.first?.displayName
                ?? model.selectedDevice?.volumeName
                ?? "Connected"
        }
        if !model.connectedUSBDevices.isEmpty {
            return model.mtpDependencyStatus.isReady ? "Detected" : "Needs MTP"
        }
        return "Not connected"
    }
}

// MARK: - Sheets shared with On Watch

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
