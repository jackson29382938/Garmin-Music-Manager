import Foundation

@MainActor
final class TransferLogStore: ObservableObject {
    static let maxLines = 500

    @Published private(set) var lines: [String] = []

    func append(_ message: String) {
        lines.append(LogFormatter.timestamped(message))
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }

    func clear() {
        lines.removeAll()
    }
}
