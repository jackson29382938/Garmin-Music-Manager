import Foundation
import GarminMusicCore

// MARK: - Wizard step machine

/// Explicit Guided Transfer wizard steps (one panel at a time).
enum GuidedWizardStep: Int, CaseIterable, Identifiable, Comparable {
    case pairWatch = 0
    case chooseMode
    case analyze
    case reviewPlan
    case confirmPlan
    case transferProgress
    case completeSummary
    case errorRecovery

    var id: Int { rawValue }

    static func < (lhs: GuidedWizardStep, rhs: GuidedWizardStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .pairWatch: return "Connect watch"
        case .chooseMode: return "Choose direction"
        case .analyze: return "Analyze"
        case .reviewPlan: return "Review plan"
        case .confirmPlan: return "Confirm"
        case .transferProgress: return "Transfer"
        case .completeSummary: return "Done"
        case .errorRecovery: return "Problem"
        }
    }

    var systemImage: String {
        switch self {
        case .pairWatch: return "applewatch"
        case .chooseMode: return "arrow.left.arrow.right"
        case .analyze: return "magnifyingglass"
        case .reviewPlan: return "list.bullet.rectangle"
        case .confirmPlan: return "checkmark.shield"
        case .transferProgress: return "arrow.down.circle"
        case .completeSummary: return "checkmark.circle"
        case .errorRecovery: return "exclamationmark.triangle"
        }
    }

    static var progressSteps: [GuidedWizardStep] {
        [.pairWatch, .chooseMode, .analyze, .reviewPlan, .confirmPlan, .transferProgress, .completeSummary]
    }
}

// MARK: - Transfer direction

enum GuidedTransferMode: String, CaseIterable, Identifiable {
    case toWatch
    case fromWatch
    case bothWays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toWatch: return "Send music to watch"
        case .fromWatch: return "Import music from watch"
        case .bothWays: return "Analyze both ways"
        }
    }

    var subtitle: String {
        switch self {
        case .toWatch:
            return "Scan your Mac library (queue, Music folder, Apple Music locals) and send what’s not on the watch."
        case .fromWatch:
            return "Copy music from the watch into a folder on this Mac."
        case .bothWays:
            return "Compare libraries both ways. Resolve conflicts, then approve before anything moves."
        }
    }

    var systemImage: String {
        switch self {
        case .toWatch: return "applewatch.and.arrow.forward"
        case .fromWatch: return "arrow.down.doc"
        case .bothWays: return "arrow.triangle.2.circlepath"
        }
    }
}

// MARK: - Library scan sources

enum GuidedLibraryScanSource: String, CaseIterable, Identifiable {
    case transferQueue
    case musicFolder
    case appleMusicLocal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transferQueue: return "Transfer queue"
        case .musicFolder: return "~/Music folder"
        case .appleMusicLocal: return "Apple Music (local)"
        }
    }

    var systemImage: String {
        switch self {
        case .transferQueue: return "list.bullet"
        case .musicFolder: return "folder"
        case .appleMusicLocal: return "music.note.list"
        }
    }
}

// MARK: - Plan buckets & conflicts

enum GuidedPlanBucket: String, CaseIterable, Identifiable {
    case toWatch
    case fromWatch
    case alreadyBoth
    case conflict
    case cannotTransfer
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toWatch: return "To watch"
        case .fromWatch: return "From watch"
        case .alreadyBoth: return "Already on both"
        case .conflict: return "Conflicts"
        case .cannotTransfer: return "Cannot transfer"
        case .skip: return "Info"
        }
    }
}

/// User choice for a Mac↔watch conflict pair.
enum GuidedConflictResolution: String, CaseIterable, Identifiable {
    case skipBoth
    case sendMacVersion
    case importWatchVersion
    case keepBothCopies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skipBoth: return "Skip both"
        case .sendMacVersion: return "Send Mac → watch"
        case .importWatchVersion: return "Import watch → Mac"
        case .keepBothCopies: return "Do both"
        }
    }

    var help: String {
        switch self {
        case .skipBoth: return "Leave both sides unchanged."
        case .sendMacVersion: return "Copy the Mac file to the watch (does not delete the watch copy)."
        case .importWatchVersion: return "Copy the watch file into ~/Music/Garmin Imports."
        case .keepBothCopies: return "Send Mac version to the watch and import the watch file to the Mac."
        }
    }
}

enum GuidedPlanDirection: String, Codable {
    case toWatch
    case fromWatch
    case none
    case bidirectional
}

struct GuidedPlanItem: Identifiable, Hashable {
    let id: UUID
    var bucket: GuidedPlanBucket
    var direction: GuidedPlanDirection
    var displayName: String
    var detail: String?
    var byteCount: Int64
    var reason: String?
    var trackID: UUID?
    var deviceFileID: String?
    var isIncluded: Bool

    // Conflict UI
    var macLabel: String?
    var watchLabel: String?
    var matchKind: String?
    var resolution: GuidedConflictResolution?

    init(
        id: UUID = UUID(),
        bucket: GuidedPlanBucket,
        direction: GuidedPlanDirection,
        displayName: String,
        detail: String? = nil,
        byteCount: Int64 = 0,
        reason: String? = nil,
        trackID: UUID? = nil,
        deviceFileID: String? = nil,
        isIncluded: Bool = true,
        macLabel: String? = nil,
        watchLabel: String? = nil,
        matchKind: String? = nil,
        resolution: GuidedConflictResolution? = nil
    ) {
        self.id = id
        self.bucket = bucket
        self.direction = direction
        self.displayName = displayName
        self.detail = detail
        self.byteCount = byteCount
        self.reason = reason
        self.trackID = trackID
        self.deviceFileID = deviceFileID
        self.isIncluded = isIncluded
        self.macLabel = macLabel
        self.watchLabel = watchLabel
        self.matchKind = matchKind
        self.resolution = resolution
    }
}

struct GuidedCatalogStats: Equatable {
    var queueCount: Int = 0
    var musicFolderCount: Int = 0
    var appleMusicCount: Int = 0
    var uniqueTracks: Int = 0

    var summaryLine: String {
        "\(uniqueTracks) unique tracks · queue \(queueCount) · Music folder \(musicFolderCount) · Apple Music \(appleMusicCount)"
    }
}

struct GuidedTransferPlan: Equatable {
    var mode: GuidedTransferMode
    var items: [GuidedPlanItem]
    var analyzedAt: Date
    var watchDisplayName: String
    var freeBytesOnWatch: Int64?
    var catalogStats: GuidedCatalogStats

    var conflictItems: [GuidedPlanItem] {
        items.filter { $0.bucket == .conflict }
    }

    /// Items that will send to the watch given toggles + conflict resolutions.
    var toWatchItems: [GuidedPlanItem] {
        items.filter { item in
            switch item.bucket {
            case .toWatch:
                return item.isIncluded
            case .conflict:
                guard item.isIncluded else { return false }
                switch item.resolution ?? .skipBoth {
                case .sendMacVersion, .keepBothCopies: return item.trackID != nil
                default: return false
                }
            default:
                return false
            }
        }
    }

    var fromWatchItems: [GuidedPlanItem] {
        items.filter { item in
            switch item.bucket {
            case .fromWatch:
                return item.isIncluded
            case .conflict:
                guard item.isIncluded else { return false }
                switch item.resolution ?? .skipBoth {
                case .importWatchVersion, .keepBothCopies: return item.deviceFileID != nil
                default: return false
                }
            default:
                return false
            }
        }
    }

    var skippedItems: [GuidedPlanItem] {
        items.filter { item in
            switch item.bucket {
            case .cannotTransfer, .skip, .alreadyBoth:
                return true
            case .conflict:
                return (item.resolution ?? .skipBoth) == .skipBoth || !item.isIncluded
            case .toWatch, .fromWatch:
                return !item.isIncluded
            }
        }
    }

    var toWatchBytes: Int64 {
        toWatchItems.reduce(0) { $0 + $1.byteCount }
    }

    var fromWatchBytes: Int64 {
        fromWatchItems.reduce(0) { $0 + $1.byteCount }
    }

    var totalMoveBytes: Int64 { toWatchBytes + fromWatchBytes }

    var willExceedStorage: Bool {
        guard let free = freeBytesOnWatch else { return false }
        return toWatchBytes > free
    }
}

struct GuidedTransferSummary: Equatable {
    var mode: GuidedTransferMode
    var watchName: String
    var toWatchCount: Int
    var fromWatchCount: Int
    var skippedCount: Int
    var failedCount: Int
    var bytesTransferred: Int64
    var duration: TimeInterval
    var wasCancelled: Bool
    var failedNames: [String]
    var message: String
}
