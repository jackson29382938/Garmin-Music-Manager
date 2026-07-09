import GarminMusicCore
import SwiftUI

/// Shared chrome for the On Watch / device browser (banners + collection rows).
struct DeviceCollectionRow: View {
    let collection: DeviceCollection

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .lineLimit(1)
                Text("\(collection.totalItemCount) item(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private var systemImage: String {
        switch collection.kind {
        case .allMusic:
            return "music.note.list"
        case .playlist:
            return "list.bullet.rectangle"
        case .album:
            return "opticaldisc"
        case .folder:
            return "folder"
        }
    }
}

struct DeviceOperationBanner: View {
    let operation: DeviceOperation
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if operation.lastError == nil {
                    if operation.progress == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.primaryLine)
                        .font(.caption.bold())
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let lastError = operation.lastError {
                        Text(lastError)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let progress = operation.progress {
                        HStack(spacing: 6) {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let itemLabel = operation.itemLabel, itemLabel != operation.primaryLine {
                                Text(operation.phase)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Spacer()

                if operation.canCancel, operation.lastError == nil, let onCancel {
                    Button("Cancel", action: onCancel)
                        .controlSize(.small)
                }
            }

            if let progress = operation.progress, operation.lastError == nil {
                ProgressView(value: progress)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }
}

struct DeviceStatusBanner: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
    }
}
