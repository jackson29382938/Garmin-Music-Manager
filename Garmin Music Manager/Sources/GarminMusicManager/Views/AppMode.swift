import Foundation

/// Top-level navigation modes for the simplified shell.
enum AppMode: String, CaseIterable, Identifiable {
    case transfer
    case onWatch
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transfer: return "Transfer"
        case .onWatch: return "On Watch"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .transfer: return "arrow.down.circle.fill"
        case .onWatch: return "applewatch"
        case .settings: return "gearshape"
        }
    }
}
