import Foundation
import GarminMusicCore

/// How newly imported tracks are selected in the Mac queue.
enum ImportSelectionMode: String, CaseIterable, Identifiable, Codable {
    case allReady
    case none
    case nonDuplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allReady: return "All ready tracks"
        case .none: return "None"
        case .nonDuplicates: return "Ready, not already on device"
        }
    }
}

/// How aggressively tracks are matched to files already on the watch.
enum DuplicateMatchMode: String, CaseIterable, Identifiable, Codable {
    case nameAndSize
    case smart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nameAndSize: return "Name + size only"
        case .smart: return "Smart (name, metadata, duration)"
        }
    }
}

/// Behavior when selected size exceeds free device storage.
enum StorageExceedPolicy: String, CaseIterable, Identifiable, Codable {
    case warnOnly
    case blockSend
    case ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warnOnly: return "Warn only"
        case .blockSend: return "Block send"
        case .ignore: return "Ignore"
        }
    }
}

/// Mac library / import / matching preferences.
struct LibrarySettings: Codable, Equatable {
    var restoreQueueOnLaunch: Bool
    var importSelectionMode: ImportSelectionMode
    var skipDuplicatesWhenSending: Bool
    var autoDeselectDuplicates: Bool
    var duplicateMatchMode: DuplicateMatchMode
    /// Seconds of duration tolerance for smart matching (0.5…5).
    var durationMatchToleranceSeconds: Double
    /// Fast import skips deep AV metadata (title/artist/duration/codec).
    var fastImport: Bool
    /// Max concurrent metadata scans; 0 = unlimited (legacy).
    var importConcurrency: Int
    /// Compatibility warning threshold in MB (separate from compress).
    var largeFileWarningMB: Int
    var storageExceedPolicy: StorageExceedPolicy
    var defaultDeviceSort: DeviceFileSort
    var rememberLastAppMode: Bool
    var lastAppMode: String

    static let durationToleranceRange: ClosedRange<Double> = 0.5...5.0
    static let importConcurrencyRange: ClosedRange<Int> = 0...32
    static let largeFileWarningMBRange: ClosedRange<Int> = 10...2000

    static let `default` = LibrarySettings(
        restoreQueueOnLaunch: true,
        importSelectionMode: .allReady,
        skipDuplicatesWhenSending: false,
        autoDeselectDuplicates: false,
        duplicateMatchMode: .smart,
        durationMatchToleranceSeconds: 1.5,
        fastImport: false,
        importConcurrency: 0,
        largeFileWarningMB: 250,
        storageExceedPolicy: .warnOnly,
        defaultDeviceSort: .nameAscending,
        rememberLastAppMode: true,
        lastAppMode: AppMode.transfer.rawValue
    )

    mutating func clamp() {
        durationMatchToleranceSeconds = min(
            Self.durationToleranceRange.upperBound,
            max(Self.durationToleranceRange.lowerBound, durationMatchToleranceSeconds)
        )
        importConcurrency = min(
            Self.importConcurrencyRange.upperBound,
            max(Self.importConcurrencyRange.lowerBound, importConcurrency)
        )
        largeFileWarningMB = min(
            Self.largeFileWarningMBRange.upperBound,
            max(Self.largeFileWarningMBRange.lowerBound, largeFileWarningMB)
        )
    }

    var clamped: LibrarySettings {
        var copy = self
        copy.clamp()
        return copy
    }

    var largeFileWarningBytes: Int64 {
        Int64(largeFileWarningMB) * 1_000_000
    }
}
