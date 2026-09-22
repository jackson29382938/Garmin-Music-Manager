import Foundation

/// Where a drag originated.
enum DragSourceKind: String, Codable, Hashable, Sendable {
    case localFolder
    case device
    case appleMusic
    case externalFinder
    case transferQueue
}

/// Logical drop destination.
enum DropDestination: Hashable, Sendable {
    case localFolder(URL)
    case deviceMusicRoot
    case devicePlaylistFolder(name: String)
    case transferQueue
    case railTab(AppMode)
    case externalFinder
}

/// Resolved operation after validation + modifiers.
enum DropOperation: Hashable, Sendable {
    case copy
    case move
    case transferCopy
    case transferMove
    case importExternal
    case rejected(String)

    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    var deletesSource: Bool {
        switch self {
        case .move, .transferMove: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        case .transferCopy: return "Copy"
        case .transferMove: return "Move"
        case .importExternal: return "Import"
        case .rejected(let reason): return reason
        }
    }

    var dropOverlayLabel: String {
        // Prefer destination-aware `dropOverlayLabel(for:)` when the destination is known.
        switch self {
        case .copy: return "Copy here"
        case .move: return "Move here"
        case .transferCopy: return "Copy"
        case .transferMove: return "Move"
        case .importExternal: return "Import here"
        case .rejected: return "Not allowed"
        }
    }
}

/// Snapshot of items being dragged.
struct DragItemSet: Hashable, Sendable {
    var localURLs: [URL]
    var deviceFileIDs: [String]
    var sourceKind: DragSourceKind
    var totalByteCount: Int64
    var displayNames: [String]

    var isEmpty: Bool { localURLs.isEmpty && deviceFileIDs.isEmpty }

    var itemCount: Int {
        let local = localURLs.count
        let device = deviceFileIDs.count
        if local > 0 { return local }
        if device > 0 { return device }
        return displayNames.count
    }

    var previewLabel: String {
        if itemCount <= 1 {
            return displayNames.first ?? localURLs.first?.lastPathComponent ?? "1 item"
        }
        return "\(itemCount) items"
    }

    static let empty = DragItemSet(
        localURLs: [],
        deviceFileIDs: [],
        sourceKind: .localFolder,
        totalByteCount: 0,
        displayNames: []
    )
}

/// Context needed to validate / resolve a drop (pure data, no UI).
struct DropEvaluationContext: Sendable {
    var deviceConnected: Bool
    var deviceConfigured: Bool
    var availableCapacity: Int64?
    var isBusy: Bool
    var overwritePolicy: OverwritePolicy
    var largeFileWarningBytes: Int64
    var storageExceedPolicy: StorageExceedPolicy
    /// True when source and destination resolve to the same local folder path.
    var isSameLocalFolder: Bool
    /// True when all local URLs share a volume with the destination folder.
    var sameVolumeAsDestination: Bool
    /// Destination would receive files that already exist (name collision under replace/keepBoth).
    var hasNameCollisions: Bool
    /// Estimated bytes that would be replaced (for confirm).
    var collidingByteCount: Int64

    static let idle = DropEvaluationContext(
        deviceConnected: false,
        deviceConfigured: false,
        availableCapacity: nil,
        isBusy: false,
        overwritePolicy: .skipIdentical,
        largeFileWarningBytes: 250_000_000,
        storageExceedPolicy: .warnOnly,
        isSameLocalFolder: false,
        sameVolumeAsDestination: true,
        hasNameCollisions: false,
        collidingByteCount: 0
    )
}

/// Pending drop awaiting user confirmation.
struct PendingDropRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    var items: DragItemSet
    var destination: DropDestination
    var operation: DropOperation
    var destinationLabel: String
    var sourceLabel: String
    var warnings: [String]

    init(
        id: UUID = UUID(),
        items: DragItemSet,
        destination: DropDestination,
        operation: DropOperation,
        destinationLabel: String,
        sourceLabel: String,
        warnings: [String] = []
    ) {
        self.id = id
        self.items = items
        self.destination = destination
        self.operation = operation
        self.destinationLabel = destinationLabel
        self.sourceLabel = sourceLabel
        self.warnings = warnings
    }
}

/// Modifier flags relevant to drop resolution (captured at drop time).
struct DropModifierFlags: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let command = DropModifierFlags(rawValue: 1 << 0)
    static let option = DropModifierFlags(rawValue: 1 << 1)
    static let none: DropModifierFlags = []
}
