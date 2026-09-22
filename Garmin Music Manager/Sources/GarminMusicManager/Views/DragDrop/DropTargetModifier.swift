import SwiftUI

/// Highlights a drop zone with operation-aware overlay text.
struct DropTargetModifier: ViewModifier {
    var isTargeted: Bool
    var isEnabled: Bool
    var tint: Color
    var overlayLabel: String
    var accessibilityLabel: String

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    if isTargeted && isEnabled {
                        Text(overlayLabel)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    RoundedRectangle(cornerRadius: AppTheme.panelCornerRadius, style: .continuous)
                        .strokeBorder(
                            isTargeted && isEnabled ? tint : Color.clear,
                            lineWidth: 2
                        )
                        .padding(4)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isTargeted ? overlayLabel : "")
    }
}

extension View {
    func dropTargetChrome(
        isTargeted: Bool,
        isEnabled: Bool,
        tint: Color,
        overlayLabel: String,
        accessibilityLabel: String
    ) -> some View {
        modifier(
            DropTargetModifier(
                isTargeted: isTargeted,
                isEnabled: isEnabled,
                tint: tint,
                overlayLabel: overlayLabel,
                accessibilityLabel: accessibilityLabel
            )
        )
    }
}
