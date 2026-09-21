import SwiftCrossUI
import GarminMusicCore

/// Shared visual language for the app — a clean, modern look that adapts to
/// light/dark and renders natively via each SwiftCrossUI backend.
enum Theme {
    static let accent = Color.blue

    static var card: Color { Color.adaptive(light: Color(white: 0.96), dark: Color(white: 0.16)) }
    static var cardBorder: Color { Color.adaptive(light: Color(white: 0.85), dark: Color(white: 0.28)) }
    static var subtle: Color { .gray }

    static func statusColor(_ status: TrackCompatibility.Status) -> Color {
        switch status {
        case .ready: return Color.green
        case .warning: return Color.orange
        case .blocked: return Color.red
        }
    }
}

/// Small colored pill used for compatibility status.
struct StatusBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.white)
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.top, 3)
            .padding(.bottom, 3)
            .background(color)
            .cornerRadius(6)
    }
}

/// A compact statistic tile (value over label).
struct StatChip: View {
    var value: String
    var label: String
    var tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20))
                .foregroundColor(tint)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .padding(12)
        .frame(minWidth: 84)
        .background(Theme.card)
        .cornerRadius(12)
    }
}

/// Determinate progress bar built from primitive views so it renders on every backend.
struct ProgressBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Color.blue
                    .frame(maxWidth: filledWidth(proxy.size.width), maxHeight: 10)
                Color.adaptive(light: Color(white: 0.85), dark: Color(white: 0.30))
                    .frame(maxHeight: 10)
            }
            .cornerRadius(5)
        }
        .frame(height: 10)
    }

    private func filledWidth(_ total: Double) -> Double {
        let clamped = min(1, max(0, fraction))
        return total * clamped
    }
}

/// A segmented, tappable single-choice control (labels are plain strings).
struct SegmentedPicker: View {
    var title: String
    var options: [String]
    var selected: String
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    segment(option)
                }
            }
        }
    }

    private func segment(_ option: String) -> some View {
        let isSelected = option == selected
        return Button((isSelected ? "● " : "○ ") + option) {
            onSelect(option)
        }
    }
}

/// A titled input row: caption above a text field.
struct LabeledField: View {
    var caption: String
    var placeholder: String
    var text: Binding<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            TextField(placeholder, text: text)
        }
    }
}
