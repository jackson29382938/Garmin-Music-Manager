import Foundation

/// Whether native MTP playlists update an existing same-name list or always create new.
enum PlaylistWriteStrategy: String, CaseIterable, Identifiable, Codable {
    case updateIfExists
    case alwaysCreateNew

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updateIfExists: return "Update if name exists"
        case .alwaysCreateNew: return "Always create new"
        }
    }
}

/// Transfer lifecycle and post-send behavior.
struct LifecycleSettings: Codable, Equatable {
    /// Re-list device library after a successful MTP/mounted send.
    var refreshDeviceAfterSend: Bool
    /// Shut down the long-lived MTP helper immediately after send completes.
    var releaseHelperAfterSend: Bool
    /// Remote root folder for MTP paths (default Music).
    var remoteMusicRoot: String
    var playlistWriteStrategy: PlaylistWriteStrategy
    /// Automatically start retry of failed track IDs after a partial MTP failure.
    var autoRetryFailedTransfers: Bool
    /// Post a macOS user notification when a send finishes.
    var notifyOnSendComplete: Bool

    static let `default` = LifecycleSettings(
        refreshDeviceAfterSend: true,
        releaseHelperAfterSend: false,
        remoteMusicRoot: "Music",
        playlistWriteStrategy: .updateIfExists,
        autoRetryFailedTransfers: false,
        notifyOnSendComplete: false
    )

    mutating func clamp() {
        let parts = remoteMusicRoot
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { FileNameSanitizer.sanitizePathComponent(String($0)) }
            .filter { !$0.isEmpty && $0 != "." }
        remoteMusicRoot = parts.isEmpty ? "Music" : parts.joined(separator: "/")
    }

    var clamped: LifecycleSettings {
        var copy = self
        copy.clamp()
        return copy
    }
}
