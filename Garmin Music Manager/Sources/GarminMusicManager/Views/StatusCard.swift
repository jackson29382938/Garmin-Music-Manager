import SwiftUI

struct StatusCard<Actions: View>: View {
    let title: String
    let systemImage: String
    var status: ConnectionStatus = .idle
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(
        title: String,
        systemImage: String,
        status: ConnectionStatus = .idle,
        message: String,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.status = status
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.statusColor(for: status))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Circle()
                    .fill(AppTheme.statusColor(for: status))
                    .frame(width: 8, height: 8)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actions()
        }
        .padding(12)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
    }
}
