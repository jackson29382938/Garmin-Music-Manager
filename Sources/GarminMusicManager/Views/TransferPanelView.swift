import SwiftUI

struct TransferPanelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playlist Sync")
                        .font(.headline)
                    Text(model.transferTargetDescription)
                        .font(.caption)
                        .foregroundStyle(model.destinationIsReady ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.exceedsAvailableStorage {
                        Label("Selected tracks exceed available storage", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)

                if model.isSyncing {
                    Button(role: .destructive) {
                        model.cancelSync()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .fixedSize()
                }

                Button {
                    model.prepareSyncPreview()
                } label: {
                    Label(model.isSyncing ? "Syncing..." : (model.hasMTPDestination ? "Sync Playlist to Garmin" : "Sync Playlist to Folder"), systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(!model.canSync)
            }

            if model.isSyncing {
                ProgressView(value: model.syncProgress)
            }

            DisclosureGroup("Transfer log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.transferLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 130)
            }
        }
        .padding()
    }
}

struct SyncPreviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync Preview")
                .font(.title2.bold())

            if let preview = model.syncPreview {
                Text("\(preview.copyCount) to copy, \(preview.skipCount) to skip • \(ByteCountFormatter.string(fromByteCount: preview.totalBytesToCopy, countStyle: .file))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                List(preview.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.track.displayName)
                                .font(.body)
                            Text(item.targetPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(item.action.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(item.action == .skipIdentical ? .orange : .primary)
                    }
                }

                if model.exceedsAvailableStorage {
                    Label("Warning: selected tracks may exceed available storage.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                    model.showSyncPreview = false
                }
                Button("Start Sync") {
                    dismiss()
                    model.confirmSync()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.syncPreview == nil)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
    }
}
