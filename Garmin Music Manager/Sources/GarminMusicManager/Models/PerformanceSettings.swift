import Foundation

/// Named performance profiles. Selecting a non-custom preset replaces all knobs.
enum PerformancePreset: String, CaseIterable, Identifiable, Codable {
    case balanced
    case fast
    case reliable
    case expressFriendly
    case smallFiles
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .fast: return "Fast"
        case .reliable: return "Reliable"
        case .expressFriendly: return "Express-friendly"
        case .smallFiles: return "Small files"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .balanced:
            return "Shipping defaults — solid speed with safe USB behavior."
        case .fast:
            return "Larger batches, longer session, shorter timeouts, smaller AAC. Best on a stable cable."
        case .reliable:
            return "Always re-list, batch of 1, more retries, patient timeouts. Best on flaky USB."
        case .expressFriendly:
            return "Short MTP keep-alive so Garmin Express or other tools can claim the watch sooner."
        case .smallFiles:
            return "128 kbps AAC and compress large files over 50 MB when conversion is available."
        case .custom:
            return "Your mix of settings. Pick another preset to reset to a template."
        }
    }
}

/// User-tunable transfer/session performance knobs.
/// Balanced defaults match historical hardcoded constants.
struct PerformanceSettings: Codable, Equatable {
    // MARK: - Tier A

    /// Seconds a device listing stays “fresh” for sync planning. `0` = never reuse.
    var listingReuseSeconds: TimeInterval
    /// How long the long-lived MTP helper stays warm after last use.
    var mtpSessionKeepAliveSeconds: TimeInterval
    /// Files per MTP upload batch.
    var uploadBatchSize: Int
    /// When false, auto USB/volume detect is off.
    var autoDetectDevices: Bool
    /// USB signature poll interval while auto-detect is on.
    var usbPollIntervalSeconds: TimeInterval
    /// ffmpeg AAC bitrate when converting.
    var aacBitrateKbps: Int

    // MARK: - Tier B

    /// Always force a device re-list before MTP sync planning.
    var forceRefreshBeforeSync: Bool
    /// App-layer MTP helper retries for transient USB errors.
    var mtpRetryAttempts: Int
    var mtpRetryBackoffSeconds: TimeInterval
    /// Multiplier for operation / listing timeouts (0.5…2.5).
    var operationTimeoutScale: Double
    /// When true, convert files larger than `convertLargeFilesOverMB` to AAC (needs ffmpeg).
    var compressLargeFiles: Bool
    /// Threshold in mebibytes; used only when `compressLargeFiles` is true. `0` treated as off.
    var convertLargeFilesOverMB: Int
    /// Download on-device playlist bodies when listing music (expensive on some watches).
    var includePlaylistContentsWhenBrowsing: Bool
    /// When false, helper skips post-upload size verification (faster, less safe).
    var verifyUploads: Bool

    // MARK: - Ranges

    static let listingReuseRange: ClosedRange<TimeInterval> = 0...600
    static let keepAliveRange: ClosedRange<TimeInterval> = 15...600
    static let uploadBatchRange: ClosedRange<Int> = 1...50
    static let usbPollRange: ClosedRange<TimeInterval> = 2...60
    static let aacBitrateRange: ClosedRange<Int> = 64...320
    static let retryAttemptsRange: ClosedRange<Int> = 1...8
    static let retryBackoffRange: ClosedRange<TimeInterval> = 0.2...5.0
    static let timeoutScaleRange: ClosedRange<Double> = 0.5...2.5
    static let largeFileMBRange: ClosedRange<Int> = 0...500

    static let `default` = PerformanceSettings.template(for: .balanced)

    static func template(for preset: PerformancePreset) -> PerformanceSettings {
        switch preset {
        case .balanced, .custom:
            return PerformanceSettings(
                listingReuseSeconds: 120,
                mtpSessionKeepAliveSeconds: 90,
                uploadBatchSize: 5,
                autoDetectDevices: true,
                usbPollIntervalSeconds: 6,
                aacBitrateKbps: 256,
                forceRefreshBeforeSync: false,
                mtpRetryAttempts: 3,
                mtpRetryBackoffSeconds: 0.8,
                operationTimeoutScale: 1.0,
                compressLargeFiles: false,
                convertLargeFilesOverMB: 0,
                includePlaylistContentsWhenBrowsing: false,
                verifyUploads: true
            )
        case .fast:
            return PerformanceSettings(
                listingReuseSeconds: 300,
                mtpSessionKeepAliveSeconds: 300,
                uploadBatchSize: 20,
                autoDetectDevices: true,
                usbPollIntervalSeconds: 12,
                aacBitrateKbps: 128,
                forceRefreshBeforeSync: false,
                mtpRetryAttempts: 2,
                mtpRetryBackoffSeconds: 0.5,
                operationTimeoutScale: 0.75,
                compressLargeFiles: false,
                convertLargeFilesOverMB: 0,
                includePlaylistContentsWhenBrowsing: false,
                verifyUploads: false
            )
        case .reliable:
            return PerformanceSettings(
                listingReuseSeconds: 0,
                mtpSessionKeepAliveSeconds: 180,
                uploadBatchSize: 1,
                autoDetectDevices: true,
                usbPollIntervalSeconds: 3,
                aacBitrateKbps: 256,
                forceRefreshBeforeSync: true,
                mtpRetryAttempts: 5,
                mtpRetryBackoffSeconds: 1.2,
                operationTimeoutScale: 1.5,
                compressLargeFiles: false,
                convertLargeFilesOverMB: 0,
                includePlaylistContentsWhenBrowsing: false,
                verifyUploads: true
            )
        case .expressFriendly:
            return PerformanceSettings(
                listingReuseSeconds: 60,
                mtpSessionKeepAliveSeconds: 30,
                uploadBatchSize: 5,
                autoDetectDevices: true,
                usbPollIntervalSeconds: 6,
                aacBitrateKbps: 256,
                forceRefreshBeforeSync: false,
                mtpRetryAttempts: 3,
                mtpRetryBackoffSeconds: 0.8,
                operationTimeoutScale: 1.0,
                compressLargeFiles: false,
                convertLargeFilesOverMB: 0,
                includePlaylistContentsWhenBrowsing: false,
                verifyUploads: true
            )
        case .smallFiles:
            return PerformanceSettings(
                listingReuseSeconds: 120,
                mtpSessionKeepAliveSeconds: 90,
                uploadBatchSize: 5,
                autoDetectDevices: true,
                usbPollIntervalSeconds: 6,
                aacBitrateKbps: 128,
                forceRefreshBeforeSync: false,
                mtpRetryAttempts: 3,
                mtpRetryBackoffSeconds: 0.8,
                operationTimeoutScale: 1.0,
                compressLargeFiles: true,
                convertLargeFilesOverMB: 50,
                includePlaylistContentsWhenBrowsing: false,
                verifyUploads: true
            )
        }
    }

    static func matchingPreset(for settings: PerformanceSettings) -> PerformancePreset {
        let clamped = settings.clamped
        for preset in PerformancePreset.allCases where preset != .custom {
            if template(for: preset).clamped == clamped {
                return preset
            }
        }
        return .custom
    }

    var matchedPreset: PerformancePreset {
        Self.matchingPreset(for: self)
    }

    mutating func applyPreset(_ preset: PerformancePreset) {
        guard preset != .custom else { return }
        self = Self.template(for: preset).clamped
    }

    mutating func clamp() {
        listingReuseSeconds = min(Self.listingReuseRange.upperBound, max(Self.listingReuseRange.lowerBound, listingReuseSeconds))
        mtpSessionKeepAliveSeconds = min(Self.keepAliveRange.upperBound, max(Self.keepAliveRange.lowerBound, mtpSessionKeepAliveSeconds))
        uploadBatchSize = min(Self.uploadBatchRange.upperBound, max(Self.uploadBatchRange.lowerBound, uploadBatchSize))
        usbPollIntervalSeconds = min(Self.usbPollRange.upperBound, max(Self.usbPollRange.lowerBound, usbPollIntervalSeconds))
        aacBitrateKbps = min(Self.aacBitrateRange.upperBound, max(Self.aacBitrateRange.lowerBound, aacBitrateKbps))
        mtpRetryAttempts = min(Self.retryAttemptsRange.upperBound, max(Self.retryAttemptsRange.lowerBound, mtpRetryAttempts))
        mtpRetryBackoffSeconds = min(Self.retryBackoffRange.upperBound, max(Self.retryBackoffRange.lowerBound, mtpRetryBackoffSeconds))
        operationTimeoutScale = min(Self.timeoutScaleRange.upperBound, max(Self.timeoutScaleRange.lowerBound, operationTimeoutScale))
        convertLargeFilesOverMB = min(Self.largeFileMBRange.upperBound, max(Self.largeFileMBRange.lowerBound, convertLargeFilesOverMB))
        if !compressLargeFiles {
            // Keep stored threshold but treat as inactive when master is off.
        }
    }

    var clamped: PerformanceSettings {
        var copy = self
        copy.clamp()
        return copy
    }

    /// Byte threshold for large-file compression; nil when disabled.
    var largeFileByteThreshold: Int64? {
        guard compressLargeFiles, convertLargeFilesOverMB > 0 else { return nil }
        return Int64(convertLargeFilesOverMB) * 1_048_576
    }

    // MARK: - Display helpers

    var listingReuseLabel: String {
        if listingReuseSeconds <= 0 { return "Never" }
        if listingReuseSeconds < 60 { return "\(Int(listingReuseSeconds))s" }
        let minutes = Int(listingReuseSeconds) / 60
        let seconds = Int(listingReuseSeconds) % 60
        if seconds == 0 { return "\(minutes) min" }
        return "\(minutes)m \(seconds)s"
    }

    var keepAliveLabel: String {
        if mtpSessionKeepAliveSeconds < 60 { return "\(Int(mtpSessionKeepAliveSeconds))s" }
        let minutes = Int(mtpSessionKeepAliveSeconds) / 60
        let seconds = Int(mtpSessionKeepAliveSeconds) % 60
        if seconds == 0 { return "\(minutes) min" }
        return "\(minutes)m \(seconds)s"
    }
}
