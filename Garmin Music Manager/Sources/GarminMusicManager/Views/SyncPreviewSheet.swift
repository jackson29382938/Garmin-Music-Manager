import SwiftUI

struct SyncPreviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAllItems = false

    private let previewListCap = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send Preview")
                .font(.title2.bold())

            if model.hasMTPDestination {
                Label(
                    model.syncSettings.writePlaylist
                        ? "Audio transfers over USB/MTP. A native Garmin playlist is created when the watch supports it."
                        : "Audio transfers over USB/MTP. Enable “Write playlist after send” to create a native Garmin playlist.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("Playlist: \(model.playlistName)")
                .font(.subheadline.weight(.semibold))

            if let preview = model.syncPreview {
                summaryRow(for: preview)

                actionChips(for: preview)

                if model.exceedsAvailableStorage {
                    Label(
                        "Selected tracks may exceed free space on the watch. Free space or deselect tracks before sending.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }

                List(visibleItems(from: preview)) { item in
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

                if preview.items.count > previewListCap {
                    Button(showAllItems ? "Show fewer" : "Show all \(preview.items.count) items") {
                        showAllItems.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
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

    private func summaryRow(for preview: SyncPreview) -> some View {
        Text(
            "\(preview.copyCount) to transfer · \(preview.skipCount) to skip · \(ByteCountFormatter.string(fromByteCount: preview.totalBytesToCopy, countStyle: .file))"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    private func actionChips(for preview: SyncPreview) -> some View {
        let counts = actionCounts(for: preview)
        return HStack(spacing: 8) {
            ForEach(counts, id: \.label) { item in
                if item.count > 0 {
                    StatChip(text: "\(item.count) \(item.label)", tint: item.tint)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func actionCounts(for preview: SyncPreview) -> [(label: String, count: Int, tint: Color)] {
        let copy = preview.items.filter { $0.action == .copy }.count
        let skip = preview.items.filter { $0.action == .skipIdentical }.count
        let replace = preview.items.filter { $0.action == .replace }.count
        let keepBoth = preview.items.filter { $0.action == .keepBoth }.count
        return [
            ("copy", copy, .accentColor),
            ("skip", skip, .orange),
            ("replace", replace, .blue),
            ("keep both", keepBoth, .purple)
        ]
    }

    private func visibleItems(from preview: SyncPreview) -> [SyncPreviewItem] {
        if showAllItems || preview.items.count <= previewListCap {
            return preview.items
        }
        return Array(preview.items.prefix(previewListCap))
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
        Button("Send") {
            dismiss()
            model.confirmSync()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.syncPreview == nil || model.exceedsAvailableStorage)
        .help(
            model.exceedsAvailableStorage
                ? "Free space on the watch or reduce the selection"
                : "Send to the watch"
        )
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
