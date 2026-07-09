import SwiftUI
import UniformTypeIdentifiers

/// Simplified happy-path screen: connect status → pick music → Send to Watch.
struct TransferHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false
    @State private var showTrackList = false
    @State private var showAdvanced = false
    @State private var activityExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                connectionBanner

                if model.tracks.isEmpty {
                    emptyDropZone
                }

                importSection

                if !model.tracks.isEmpty {
                    queueSection
                }

                sendSection

                // Full log stays here; progress is also sticky in ContentView while sending.
                if model.isSyncing || !model.transferLog.isEmpty {
                    activitySection
                }

                advancedSection
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refreshFFmpegAvailability() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            MultiFileDragPayload.loadURLs(from: providers) { urls in
                model.handleDroppedURLs(urls)
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppTheme.garminTint, lineWidth: 3)
                    .padding(12)
                    .overlay {
                        Text("Drop music to add")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(AppTheme.garminTint)
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.blockedTracks.count) { _, count in
            if count > 0 { showTrackList = true }
        }
        .onChange(of: model.duplicateTrackCount) { _, count in
            if count > 0 { showTrackList = true }
        }
        .onChange(of: model.tracks.count) { oldCount, newCount in
            if oldCount == 0 && newCount > 0 {
                showTrackList = model.blockedTracks.count > 0 || model.duplicateTrackCount > 0
            }
        }
        .onChange(of: model.userNotice?.kind) { _, kind in
            if kind == .error || kind == .warning {
                activityExpanded = true
            }
        }
        .onChange(of: model.isSyncing) { _, syncing in
            if syncing { activityExpanded = true }
        }
    }

    // MARK: - Connection

    private var connectionBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(connectionColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: connectionIcon)
                        .font(.title3)
                        .foregroundStyle(connectionColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(connectionTitle)
                        .font(.headline)
                    Text(connectionSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    model.refreshDevices()
                    if model.canAttemptMTP {
                        model.browseGarminMusicLibrary()
                    }
                } label: {
                    if model.deviceBrowser.isRefreshing || model.isBrowsingDevice {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.deviceBrowser.isRefreshing || model.isBrowsingDevice)
            }

            if showsRecoveryActions {
                recoveryActions
            }
        }
        .padding(16)
        .background(connectionColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var showsRecoveryActions: Bool {
        !model.destinationIsReady
    }

    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.connectedUSBDevices.isEmpty, !model.mtpDependencyStatus.isReady {
                Text(mtpRecoveryHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if !model.connectedUSBDevices.isEmpty,
                   !model.mtpDependencyStatus.isReady,
                   model.mtpDependencyStatus.canInstallViaHomebrew {
                    Button {
                        model.installMTPDependencies()
                    } label: {
                        if model.isInstallingMTPDependencies {
                            Label("Installing…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Install MTP", systemImage: "shippingbox")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.garminTint)
                    .disabled(model.isInstallingMTPDependencies)
                }

                Button {
                    model.chooseCustomGarminFolder()
                } label: {
                    Label("Choose music folder…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var mtpRecoveryHint: String {
        if model.mtpDependencyStatus.canInstallViaHomebrew {
            return "Watch detected over USB, but MTP support isn’t ready. Install MTP, or quit Garmin Express / Android File Transfer if they are open."
        }
        return "Watch detected over USB, but MTP isn’t ready. Quit Garmin Express or Android File Transfer, use the packaged app (bundles libmtp), or choose a music folder if the watch is mounted."
    }

    private var connectionTitle: String {
        if model.destinationIsReady {
            return model.connectedMTPDeviceName
                ?? model.connectedUSBDevices.first?.displayName
                ?? model.selectedDevice?.volumeName
                ?? "Watch ready"
        }
        if !model.connectedUSBDevices.isEmpty {
            return model.connectedUSBDevices.first?.displayName ?? "Garmin detected"
        }
        return "No watch connected"
    }

    private var connectionSubtitle: String {
        if model.destinationIsReady {
            if let storage = model.deviceBrowser.storageInfo,
               let free = storage.availableCapacity {
                let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                return "Connected · \(freeText) free"
            }
            return model.hasMTPDestination
                ? "Connected over USB · ready to transfer"
                : "Music folder ready"
        }
        if !model.connectedUSBDevices.isEmpty, !model.mtpDependencyStatus.isReady {
            return model.mtpDependencyStatus.message
        }
        return "Plug in your Garmin with a data USB cable, unlock it, then Refresh."
    }

    private var connectionColor: Color {
        if model.destinationIsReady { return .green }
        if !model.connectedUSBDevices.isEmpty { return .orange }
        return .secondary
    }

    private var connectionIcon: String {
        if model.destinationIsReady { return "applewatch" }
        if !model.connectedUSBDevices.isEmpty { return "cable.connector" }
        return "applewatch.slash"
    }

    // MARK: - Empty drop zone

    private var emptyDropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.title)
                .foregroundStyle(AppTheme.garminTint.opacity(0.8))
            Text("Drop audio files here")
                .font(.headline)
            Text("Or use Apple Music / Files below")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.garminTint.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .background(AppTheme.garminTint.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
    }

    // MARK: - Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want on your watch?")
                .font(.title2.bold())

            HStack(spacing: 12) {
                importCard(
                    title: "Apple Music",
                    subtitle: "Playlists & albums from Music.app",
                    systemImage: "music.note.list",
                    tint: AppTheme.macTint
                ) {
                    model.openAppleMusicBrowser()
                }

                macFilesCard
            }

            Text("or drag files onto this page")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var macFilesCard: some View {
        Menu {
            Button {
                model.chooseMusicFiles()
            } label: {
                Label("Choose Files…", systemImage: "doc")
            }
            Button {
                model.chooseMusicFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder")
            }
            Button {
                model.chooseM3UPlaylist()
            } label: {
                Label("Import M3U Playlist…", systemImage: "list.bullet.rectangle")
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.title)
                    .foregroundStyle(AppTheme.garminTint)
                Text("Files / Folder")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Audio files, folders, or M3U playlists")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .padding(16)
            .background(AppTheme.garminTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.garminTint.opacity(0.2), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private func importCard(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .padding(16)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playlist name")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            TextField("e.g. Morning Run", text: $model.playlistName)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            HStack(spacing: 8) {
                StatChip(text: "\(model.syncableTracks.count) ready", tint: .green)
                StatChip(
                    text: ByteCountFormatter.string(fromByteCount: model.selectedTracksByteCount, countStyle: .file),
                    tint: .secondary
                )
                if model.tracks.count != model.syncableTracks.count {
                    StatChip(text: "\(model.tracks.count) total", tint: .secondary)
                }
                if model.blockedTracks.count > 0 {
                    StatChip(text: "\(model.blockedTracks.count) blocked", tint: .red)
                }
                if model.duplicateTrackCount > 0 {
                    StatChip(text: "\(model.duplicateTrackCount) on watch", tint: .orange)
                }
                Spacer()
                Button(showTrackList ? "Hide tracks" : "Edit selection") {
                    withAnimation { showTrackList.toggle() }
                }
                .buttonStyle(.borderless)
            }

            if let help = model.blockedTracksHelp {
                Label(help, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.exceedsAvailableStorage {
                Label("Selection may exceed free space on the watch", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if showTrackList {
                trackList
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Select All Ready") { model.selectAllReady() }
                    .buttonStyle(.borderless)
                Button("Deselect All") { model.deselectAll() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Clear Queue", role: .destructive) { model.clearTracks() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.bottom, 8)

            List {
                ForEach($model.tracks) { $track in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $track.isSelected)
                            .labelsHidden()
                            .disabled(!track.compatibility.canCopy)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayName)
                                .lineLimit(1)
                            Text(track.compatibility.summary)
                                .font(.caption2)
                                .foregroundStyle(track.compatibility.status == .blocked ? .red : .secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(track.sizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { model.removeTracks(at: $0) }
            }
            .frame(minHeight: 160, maxHeight: 280)
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Send

    private var sendSection: some View {
        VStack(spacing: 10) {
            Button {
                model.beginSend()
            } label: {
                Label(
                    model.isSyncing ? "Sending…" : "Send to Watch",
                    systemImage: "arrow.down.circle.fill"
                )
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(AppTheme.garminTint)
            .disabled(!model.canSync)
            .keyboardShortcut("s", modifiers: [.command, .shift])

            if let reason = sendDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if model.alwaysPreviewBeforeSend {
                Text("You’ll review a send preview before transfer starts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if model.canRetryFailedTransfers {
                Button {
                    model.retryFailedTransfers()
                } label: {
                    Label(model.retryFailedTransfersTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var sendDisabledReason: String? {
        if model.canSync { return nil }
        if model.isSyncing { return "Transfer in progress…" }
        if model.syncableTracks.isEmpty {
            return model.tracks.isEmpty
                ? "Add music with Apple Music or Files above."
                : "Select at least one compatible track (Edit selection)."
        }
        if !model.destinationIsReady {
            return "Connect your Garmin watch to continue."
        }
        return nil
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.isSyncing {
                    Button("Cancel", role: .destructive) {
                        model.cancelSync()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if model.isSyncing {
                let snapshot = model.transferProgress
                ProgressView(value: snapshot?.fraction ?? model.syncProgress)
                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot?.primaryLine ?? model.transferLog.last ?? "Transferring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(snapshot?.percentLabel ?? "\(Int((model.syncProgress * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let bytes = snapshot?.bytesLabel {
                    Text(bytes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if let last = model.transferLog.last {
                Text(last)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            DisclosureGroup("Transfer log", isExpanded: $activityExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if model.transferLog.isEmpty {
                            Text("Activity will appear here during send.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.recentTransferLogLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 140)
            }
            .font(.caption)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DisclosureGroup("Advanced options", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Overwrite", selection: $model.syncSettings.overwritePolicy) {
                    ForEach(OverwritePolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                Picker("Folders", selection: $model.syncSettings.organizationPolicy) {
                    ForEach(OrganizationPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                Toggle("Write playlist after send", isOn: $model.syncSettings.writePlaylist)
                Toggle("Convert ALAC/FLAC to AAC", isOn: convertToggleBinding)
                if model.needsFFmpegInstall {
                    Label(
                        "ffmpeg not installed — conversion will fail until you run: brew install ffmpeg",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else if model.syncSettings.convertIncompatibleFormats, model.isFFmpegAvailable {
                    Label("ffmpeg ready for ALAC/FLAC conversion", systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Toggle("Always preview before send", isOn: $model.alwaysPreviewBeforeSend)

                Text("These options are also available in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if model.destinationMode == .customFolder || model.activeDestination != nil {
                    Text("Destination: \(model.destinationDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.chooseCustomGarminFolder()
                } label: {
                    Label("Choose destination folder…", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    private var convertToggleBinding: Binding<Bool> {
        Binding(
            get: { model.syncSettings.convertIncompatibleFormats },
            set: { enabled in
                model.syncSettings.convertIncompatibleFormats = enabled
                if enabled {
                    model.warnIfConversionNeedsFFmpeg()
                }
            }
        )
    }
}
