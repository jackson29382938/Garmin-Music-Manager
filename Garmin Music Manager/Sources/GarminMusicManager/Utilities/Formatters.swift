import Foundation

enum DurationFormatter {
    static func format(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum LogFormatter {
    static func timestamped(_ message: String) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return "[\(formatter.string(from: Date()))] \(message)"
    }
}
