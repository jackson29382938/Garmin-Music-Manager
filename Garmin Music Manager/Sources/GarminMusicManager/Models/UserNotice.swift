import Foundation

enum UserNoticeKind: Equatable {
    case info
    case success
    case warning
    case error
}

enum UserNoticeAction: Equatable {
    case showOnWatch
    case retryFailed
}

/// Stable identity for notices (avoids matching on localized title strings).
enum UserNoticeCode: Equatable {
    case deviceBusy
    case mtpNotReady
    case nothingToSend
}

struct UserNotice: Identifiable, Equatable {
    let id: UUID
    let kind: UserNoticeKind
    let title: String
    let message: String?
    let action: UserNoticeAction?
    let code: UserNoticeCode?

    init(
        id: UUID = UUID(),
        kind: UserNoticeKind,
        title: String,
        message: String? = nil,
        action: UserNoticeAction? = nil,
        code: UserNoticeCode? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.action = action
        self.code = code
    }

    var actionTitle: String? {
        switch action {
        case .showOnWatch: return "View on Watch"
        case .retryFailed: return "Retry / continue"
        case nil: return nil
        }
    }
}

/// Pure builders for transfer outcome banners (unit-testable).
enum TransferCompletionNotice {
    static func forMTP(_ result: MTPSyncResult, canRetry: Bool) -> UserNotice {
        if result.wasCancelled {
            if result.uploadedCount > 0 || result.failedCount > 0 || !result.remainingTrackIDs.isEmpty {
                var parts: [String] = []
                if result.uploadedCount > 0 {
                    parts.append("Sent \(result.uploadedCount) before cancel.")
                }
                if result.failedCount > 0 {
                    parts.append("\(result.failedCount) failed.")
                }
                if !result.remainingTrackIDs.isEmpty {
                    parts.append("\(result.remainingTrackIDs.count) not attempted.")
                }
                if let name = result.playlistName {
                    parts.append("Playlist “\(name)” updated for sent tracks.")
                }
                let action: UserNoticeAction? = canRetry
                    ? .retryFailed
                    : (result.uploadedCount > 0 ? .showOnWatch : nil)
                return UserNotice(
                    kind: .warning,
                    title: "Send cancelled",
                    message: parts.isEmpty ? nil : parts.joined(separator: " "),
                    action: action
                )
            }
            return UserNotice(kind: .info, title: "Send cancelled", message: nil)
        }

        if result.failedCount > 0 {
            return UserNotice(
                kind: .warning,
                title: "Partially sent",
                message: "Sent \(result.uploadedCount), failed \(result.failedCount).",
                action: canRetry ? .retryFailed : (result.uploadedCount > 0 ? .showOnWatch : nil)
            )
        }

        if result.uploadedCount == 0, result.replacedCount == 0, result.skippedCount > 0 {
            return UserNotice(
                kind: .success,
                title: "Already on watch",
                message: "All \(result.skippedCount) selected track(s) were already present.",
                action: .showOnWatch
            )
        }

        var parts: [String] = []
        if result.uploadedCount > 0 { parts.append("sent \(result.uploadedCount)") }
        if result.skippedCount > 0 { parts.append("skipped \(result.skippedCount)") }
        if result.replacedCount > 0 { parts.append("replaced \(result.replacedCount)") }
        if let name = result.playlistName { parts.append("playlist “\(name)”") }
        return UserNotice(
            kind: .success,
            title: "Send complete",
            message: parts.isEmpty ? "Transfer finished." : parts.joined(separator: " · "),
            action: .showOnWatch
        )
    }

    static func forMounted(_ result: SyncResult) -> UserNotice {
        var parts: [String] = []
        if result.copiedCount > 0 { parts.append("copied \(result.copiedCount)") }
        if result.skippedCount > 0 { parts.append("skipped \(result.skippedCount)") }
        if result.replacedCount > 0 { parts.append("replaced \(result.replacedCount)") }
        parts.append(result.playlistURL.lastPathComponent)
        return UserNotice(
            kind: .success,
            title: "Send complete",
            message: parts.joined(separator: " · "),
            action: .showOnWatch
        )
    }

    static func cancelled() -> UserNotice {
        UserNotice(kind: .info, title: "Send cancelled", message: nil)
    }

    static func failed(_ message: String) -> UserNotice {
        UserNotice(kind: .error, title: "Send failed", message: message)
    }

    static func deviceBusy() -> UserNotice {
        UserNotice(
            kind: .warning,
            title: "Watch is busy",
            message: "Close Garmin Express, OpenMTP, or Android File Transfer, unplug and reconnect the watch, then Refresh.",
            code: .deviceBusy
        )
    }
}

/// Pure rules for when Send opens the preview sheet (unit-testable).
enum SendPreviewPolicy {
    static func shouldShowPreview(
        alwaysPreview: Bool,
        exceedsAvailableStorage: Bool,
        preview: SyncPreview
    ) -> Bool {
        if alwaysPreview { return true }
        if exceedsAvailableStorage { return true }
        return preview.items.contains { $0.action == .replace || $0.action == .keepBoth }
    }
}
