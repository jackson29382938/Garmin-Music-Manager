import SwiftUI

enum PanelSide {
    case mac
    case garmin
}

enum ConnectionStatus {
    case ready
    case warning
    case error
    case idle
}

enum AppTheme {
    static let macTint = Color(red: 0.20, green: 0.45, blue: 0.95)
    static let garminTint = Color(red: 0.0, green: 0.55, blue: 0.65)
    static let cardCornerRadius: CGFloat = 10
    static let panelCornerRadius: CGFloat = 8

    static func panelBackground(for side: PanelSide) -> Color {
        switch side {
        case .mac:
            return macTint.opacity(0.06)
        case .garmin:
            return garminTint.opacity(0.06)
        }
    }

    static func panelAccent(for side: PanelSide) -> Color {
        switch side {
        case .mac:
            return macTint
        case .garmin:
            return garminTint
        }
    }

    static func statusColor(for status: ConnectionStatus) -> Color {
        switch status {
        case .ready:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        case .idle:
            return .secondary
        }
    }
}

struct StatChip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    width = geometry.size.width
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    width = newWidth
                }
        }
    }
}
