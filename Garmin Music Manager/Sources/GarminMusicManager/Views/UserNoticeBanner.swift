import SwiftUI

/// Global status banner (success / warning / error / info) with optional CTA.
struct UserNoticeBanner: View {
    let notice: UserNotice
    var onAction: (() -> Void)? = nil
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                if let message = notice.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle = notice.actionTitle, let onAction {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var iconName: String {
        switch notice.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Compact transfer/device-op progress shown under the mode picker on every tab.
struct StickyTransferProgressBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ProgressView(value: progressValue)
                    .frame(maxWidth: .infinity)
                Text(percentText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
                if model.isSyncing {
                    Button("Cancel", role: .destructive) {
                        model.cancelSync()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                } else if model.isManagingDeviceFiles {
                    Button("Cancel", role: .destructive) {
                        model.cancelDeviceOperation()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.panelBackground(for: .garmin).opacity(0.55))
    }

    private var progressValue: Double {
        if model.isSyncing {
            return min(1, max(0, model.syncProgress))
        }
        if let op = model.deviceBrowser.operation, let p = op.progress {
            return min(1, max(0, p))
        }
        return 0
    }

    private var percentText: String {
        "\(Int((progressValue * 100).rounded()))%"
    }

    private var statusLine: String {
        if model.isSyncing {
            return model.transferProgress?.primaryLine
                ?? model.transferLog.last
                ?? "Sending to watch…"
        }
        if let op = model.deviceBrowser.operation {
            let line = op.primaryLine
            return line.isEmpty ? "Working on watch…" : line
        }
        if model.isManagingDeviceFiles {
            return "Updating watch…"
        }
        return "Working…"
    }
}
