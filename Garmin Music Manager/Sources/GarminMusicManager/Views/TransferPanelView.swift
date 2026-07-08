import SwiftUI

struct TransferPanelView: View {
    @EnvironmentObject private var model: AppModel
    @State private var logExpanded = false
    @State private var availableWidth: CGFloat = 0

    private var usesCompactLayout: Bool {
        availableWidth > 0 && availableWidth < 640
    }

    var body: some View {
        VStack(spacing: usesCompactLayout ? 8 : 12) {
            if usesCompactLayout {
                compactSummary
            } else {
                regularSummary
            }

            if model.isSyncing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: model.syncProgress)
                    HStack {
                        Text(model.transferLog.last ?? "Transferring…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(Int((model.syncProgress * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DisclosureGroup("Transfer log", isExpanded: $logExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.transferLog.isEmpty {
                            Text("Activity will appear here during sync.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.transferLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: usesCompactLayout ? 88 : 130)
            }
        }
        .padding(usesCompactLayout ? 10 : 16)
        .background(AppTheme.panelBackground(for: .garmin).opacity(0.4))
        .background(WidthReader(width: $availableWidth))
        .onChange(of: model.isSyncing) { _, syncing in
            if syncing { logExpanded = true }
        }
        .onChange(of: model.transferLog.count) { _, _ in
            if model.transferLog.last?.contains("failed") == true {
                logExpanded = true
            }
        }
    }

    private var regularSummary: some View {
        HStack(alignment: .top, spacing: 16) {
            transferDetails
                .frame(maxWidth: .infinity, alignment: .leading)

            syncActions(compact: false)
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            transferDetails
            syncActions(compact: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var transferDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Step 4: Sync Playlist", systemImage: "arrow.down.circle")
                .font(.headline)
                .foregroundStyle(AppTheme.panelAccent(for: .garmin))
                .lineLimit(1)

            playlistEditor

            Text(model.transferTargetDescription)
                .font(.caption)
                .foregroundStyle(model.destinationIsReady ? Color.secondary : Color.red)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(model.syncSummaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if model.exceedsAvailableStorage {
                Label("Selected tracks exceed available storage", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var playlistEditor: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                playlistLabel
                playlistField
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
            }

            VStack(alignment: .leading, spacing: 4) {
                playlistLabel
                playlistField
            }
        }
    }

    private var playlistLabel: some View {
        Text("Playlist")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var playlistField: some View {
        TextField("Playlist name", text: $model.playlistName)
            .textFieldStyle(.roundedBorder)
            .onChange(of: model.playlistName) { _, _ in
                model.updateDuplicateFlags()
            }
    }

    private func syncActions(compact: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                cancelButton
                syncButton(compact: compact)
            }

            VStack(alignment: .trailing, spacing: 8) {
                cancelButton
                syncButton(compact: true)
            }
        }
    }

    @ViewBuilder
    private var cancelButton: some View {
        if model.isSyncing {
            Button(role: .destructive) {
                model.cancelSync()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        }
    }

    private func syncButton(compact: Bool) -> some View {
        Button {
            model.prepareSyncPreview()
        } label: {
            Label(syncButtonTitle(compact: compact), systemImage: "arrow.down.doc")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSync)
        .help("Preview and sync the full playlist with organization and overwrite settings (⌘⇧S)")
    }

    private func syncButtonTitle(compact: Bool) -> String {
        if model.isSyncing { return "Syncing…" }
        if compact { return "Sync Playlist" }
        return model.hasMTPDestination ? "Sync Playlist to Garmin" : "Sync Playlist to Folder"
    }
}

struct SyncPreviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync Preview")
                .font(.title2.bold())

            if model.hasMTPDestination {
                Label("Only audio files transfer over MTP. Playlists are managed on the watch.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let preview = model.syncPreview {
                Text("\(preview.copyCount) to transfer, \(preview.skipCount) to skip · \(ByteCountFormatter.string(fromByteCount: preview.totalBytesToCopy, countStyle: .file))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                List(preview.items) { item in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            syncPreviewText(for: item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            actionBadge(for: item.action)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            syncPreviewText(for: item)
                            actionBadge(for: item.action)
                        }
                    }
                }

                if model.exceedsAvailableStorage {
                    Label("Warning: selected tracks may exceed available storage.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer()
                    cancelButton
                    startSyncButton
                }

                VStack(alignment: .trailing, spacing: 8) {
                    cancelButton
                    startSyncButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
    }

    private func syncPreviewText(for item: SyncPreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.track.displayName)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(item.targetPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            dismiss()
            model.showSyncPreview = false
        }
    }

    private var startSyncButton: some View {
        Button("Start Sync") {
            dismiss()
            model.confirmSync()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.syncPreview == nil)
    }

    @ViewBuilder
    private func actionBadge(for action: SyncPreviewItem.SyncAction) -> some View {
        let (color, text): (Color, String) = switch action {
        case .copy: (.accentColor, action.rawValue)
        case .skipIdentical: (.orange, action.rawValue)
        case .replace: (.blue, action.rawValue)
        case .keepBoth: (.purple, action.rawValue)
        }

        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
