import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode: AppMode = .transfer
    @StateObject private var guidedSession = GuidedTransferSession()

    private var showsStickyProgress: Bool {
        // Guided wizard has its own progress panel.
        guard mode != .guided else { return false }
        return model.isSyncing || model.isManagingDeviceFiles
    }

    var body: some View {
        HStack(spacing: 0) {
            leftRail
            Divider()
            mainColumn
        }
        .onAppear {
            if model.librarySettings.rememberLastAppMode,
               let saved = AppMode(rawValue: model.librarySettings.lastAppMode) {
                mode = saved
            }
        }
        .onChange(of: mode) { _, newMode in
            if newMode != .guided, guidedSession.step != .transferProgress {
                guidedSession.cancelAnalysisOnly()
            }
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
        .sheet(isPresented: $model.showCreatePlaylistSheet) {
            CreatePlaylistSheet()
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

    // MARK: - Left rail

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AppLogoMark(size: 22)
                Text("Garmin Music")
                    .font(.headline)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)

            // Prominent Guided Transfer entry
            Button {
                mode = .guided
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guided Transfer")
                            .font(.subheadline.weight(.semibold))
                        Text("Simple step-by-step")
                            .font(.caption2)
                            .opacity(0.85)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(mode == .guided ? Color.white : AppTheme.garminTint)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(mode == .guided ? AppTheme.garminTint : AppTheme.garminTint.opacity(0.12))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.garminTint.opacity(mode == .guided ? 0 : 0.35), lineWidth: 1.5)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Open Guided Transfer wizard (⌘⇧G)")
            .accessibilityLabel("Guided Transfer")
            .accessibilityHint("Opens a simple step-by-step music transfer wizard")

            Divider()

            ForEach([AppMode.transfer, .onWatch, .fileManager, .settings], id: \.id) { appMode in
                Button {
                    mode = appMode
                } label: {
                    Label(appMode.shortTitle, systemImage: appMode.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(
                            mode == appMode
                                ? Color.primary.opacity(0.08)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(mode == appMode ? .primary : .secondary)
                .accessibilityAddTraits(mode == appMode ? .isSelected : [])
            }

            Spacer()

            connectionPill
                .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 200)
        .background(.bar)
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if showsStickyProgress {
                StickyTransferProgressBar()
                Divider()
            }

            if mode != .guided, let notice = model.userNotice {
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
                case .guided:
                    GuidedTransferWizardView(session: guidedSession) {
                        mode = .transfer
                    }
                case .transfer:
                    TransferHomeView()
                case .onWatch:
                    OnWatchView()
                case .fileManager:
                    FileManagerView()
                case .settings:
                    SettingsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                .lineLimit(2)
        }
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

// MARK: - Sheets

private struct MoveWithinGarminSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlaylist = ""
    @State private var isCreatingNew = false
    @State private var newPlaylistName = ""

    private var playlists: [String] { model.suggestedGarminMovePlaylists }

    private var effectivePlaylistName: String {
        if isCreatingNew {
            return newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedPlaylist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Move Within Garmin", systemImage: "music.note.list")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.panelAccent(for: .garmin))

            Text("Choose a playlist on the watch. Selected tracks move into that playlist.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Playlist", selection: $selectedPlaylist) {
                ForEach(playlists, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .disabled(isCreatingNew || playlists.isEmpty)

            Toggle("Create new playlist", isOn: $isCreatingNew)

            if isCreatingNew {
                TextField("New playlist name", text: $newPlaylistName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                    model.showMoveWithinGarminSheet = false
                }
                Button("Move") {
                    dismiss()
                    model.moveSelectedWithinGarmin(toPlaylist: effectivePlaylistName)
                }
                .buttonStyle(.borderedProminent)
                .disabled(effectivePlaylistName.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            let existingPlaylists = model.deviceBrowser.collections
                .filter { $0.kind == .playlist }
                .map(\.name)
            let defaultName = FileNameSanitizer.sanitizeFileName(model.playlistName)
            if playlists.contains(where: { $0.caseInsensitiveCompare(defaultName) == .orderedSame }) {
                selectedPlaylist = playlists.first {
                    $0.caseInsensitiveCompare(defaultName) == .orderedSame
                } ?? playlists.first ?? defaultName
            } else {
                selectedPlaylist = playlists.first ?? defaultName
            }
            newPlaylistName = defaultName
            isCreatingNew = existingPlaylists.isEmpty
        }
    }
}

private struct CreatePlaylistSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trackCount: Int {
        model.selectedDeviceFiles.filter { $0.type == .audio }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("New Playlist", systemImage: "music.note.list")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.panelAccent(for: .garmin))

            Text("Create a playlist on the watch from \(trackCount) selected track\(trackCount == 1 ? "" : "s").")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                    model.showCreatePlaylistSheet = false
                }
                Button("Create") {
                    dismiss()
                    model.createPlaylistFromSelection(named: name)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || trackCount == 0)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            name = model.createPlaylistName.isEmpty
                ? FileNameSanitizer.sanitizeFileName(model.playlistName)
                : model.createPlaylistName
        }
    }
}


