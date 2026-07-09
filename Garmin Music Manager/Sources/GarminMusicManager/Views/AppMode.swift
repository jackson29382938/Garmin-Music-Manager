import Foundation

/// Top-level navigation modes for the app shell.
enum AppMode: String, CaseIterable, Identifiable {
    case guided
    case transfer
    case onWatch
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guided: return "Guided Transfer"
        case .transfer: return "Transfer"
        case .onWatch: return "On Watch"
        case .settings: return "Settings"
        }
    }

    /// Shorter label for the left rail.
    var shortTitle: String {
        switch self {
        case .guided: return "Guided"
        case .transfer: return "Transfer"
        case .onWatch: return "On Watch"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .guided: return "sparkles.rectangle.stack.fill"
        case .transfer: return "arrow.down.circle.fill"
        case .onWatch: return "applewatch"
        case .settings: return "gearshape"
        }
    }

    var isGuided: Bool { self == .guided }
}
