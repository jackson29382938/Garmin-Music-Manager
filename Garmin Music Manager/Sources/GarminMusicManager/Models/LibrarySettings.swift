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

/// Mac side of File Manager: Finder-style folders or Apple Music library.
enum FileManagerMacMode: String, CaseIterable, Identifiable, Codable {
    case folders
    case appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folders: return "Folders"
        case .appleMusic: return "Apple Music"
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
    /// File Manager Mac pane mode (`folders` / `appleMusic`).
    var fileManagerMacMode: String
    /// Last browsed Mac folder path in File Manager (Folders mode).
    var fileManagerLastFolderPath: String?

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
        lastAppMode: AppMode.transfer.rawValue,
        fileManagerMacMode: FileManagerMacMode.folders.rawValue,
        fileManagerLastFolderPath: nil
    )

    enum CodingKeys: String, CodingKey {
        case restoreQueueOnLaunch
        case importSelectionMode
        case skipDuplicatesWhenSending
        case autoDeselectDuplicates
        case duplicateMatchMode
        case durationMatchToleranceSeconds
        case fastImport
        case importConcurrency
        case largeFileWarningMB
        case storageExceedPolicy
        case defaultDeviceSort
        case rememberLastAppMode
        case lastAppMode
        case fileManagerMacMode
        case fileManagerLastFolderPath
    }

    init(
        restoreQueueOnLaunch: Bool,
        importSelectionMode: ImportSelectionMode,
        skipDuplicatesWhenSending: Bool,
        autoDeselectDuplicates: Bool,
        duplicateMatchMode: DuplicateMatchMode,
        durationMatchToleranceSeconds: Double,
        fastImport: Bool,
        importConcurrency: Int,
        largeFileWarningMB: Int,
        storageExceedPolicy: StorageExceedPolicy,
        defaultDeviceSort: DeviceFileSort,
        rememberLastAppMode: Bool,
        lastAppMode: String,
        fileManagerMacMode: String = FileManagerMacMode.folders.rawValue,
        fileManagerLastFolderPath: String? = nil
    ) {
        self.restoreQueueOnLaunch = restoreQueueOnLaunch
        self.importSelectionMode = importSelectionMode
        self.skipDuplicatesWhenSending = skipDuplicatesWhenSending
        self.autoDeselectDuplicates = autoDeselectDuplicates
        self.duplicateMatchMode = duplicateMatchMode
        self.durationMatchToleranceSeconds = durationMatchToleranceSeconds
        self.fastImport = fastImport
        self.importConcurrency = importConcurrency
        self.largeFileWarningMB = largeFileWarningMB
        self.storageExceedPolicy = storageExceedPolicy
        self.defaultDeviceSort = defaultDeviceSort
        self.rememberLastAppMode = rememberLastAppMode
        self.lastAppMode = lastAppMode
        self.fileManagerMacMode = fileManagerMacMode
        self.fileManagerLastFolderPath = fileManagerLastFolderPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LibrarySettings.default
        restoreQueueOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .restoreQueueOnLaunch)
            ?? defaults.restoreQueueOnLaunch
        importSelectionMode = try container.decodeIfPresent(ImportSelectionMode.self, forKey: .importSelectionMode)
            ?? defaults.importSelectionMode
        skipDuplicatesWhenSending = try container.decodeIfPresent(Bool.self, forKey: .skipDuplicatesWhenSending)
            ?? defaults.skipDuplicatesWhenSending
        autoDeselectDuplicates = try container.decodeIfPresent(Bool.self, forKey: .autoDeselectDuplicates)
            ?? defaults.autoDeselectDuplicates
        duplicateMatchMode = try container.decodeIfPresent(DuplicateMatchMode.self, forKey: .duplicateMatchMode)
            ?? defaults.duplicateMatchMode
        durationMatchToleranceSeconds = try container.decodeIfPresent(Double.self, forKey: .durationMatchToleranceSeconds)
            ?? defaults.durationMatchToleranceSeconds
        fastImport = try container.decodeIfPresent(Bool.self, forKey: .fastImport) ?? defaults.fastImport
        importConcurrency = try container.decodeIfPresent(Int.self, forKey: .importConcurrency)
            ?? defaults.importConcurrency
        largeFileWarningMB = try container.decodeIfPresent(Int.self, forKey: .largeFileWarningMB)
            ?? defaults.largeFileWarningMB
        storageExceedPolicy = try container.decodeIfPresent(StorageExceedPolicy.self, forKey: .storageExceedPolicy)
            ?? defaults.storageExceedPolicy
        defaultDeviceSort = try container.decodeIfPresent(DeviceFileSort.self, forKey: .defaultDeviceSort)
            ?? defaults.defaultDeviceSort
        rememberLastAppMode = try container.decodeIfPresent(Bool.self, forKey: .rememberLastAppMode)
            ?? defaults.rememberLastAppMode
        lastAppMode = try container.decodeIfPresent(String.self, forKey: .lastAppMode) ?? defaults.lastAppMode
        fileManagerMacMode = try container.decodeIfPresent(String.self, forKey: .fileManagerMacMode)
            ?? defaults.fileManagerMacMode
        fileManagerLastFolderPath = try container.decodeIfPresent(String.self, forKey: .fileManagerLastFolderPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(restoreQueueOnLaunch, forKey: .restoreQueueOnLaunch)
        try container.encode(importSelectionMode, forKey: .importSelectionMode)
        try container.encode(skipDuplicatesWhenSending, forKey: .skipDuplicatesWhenSending)
        try container.encode(autoDeselectDuplicates, forKey: .autoDeselectDuplicates)
        try container.encode(duplicateMatchMode, forKey: .duplicateMatchMode)
        try container.encode(durationMatchToleranceSeconds, forKey: .durationMatchToleranceSeconds)
        try container.encode(fastImport, forKey: .fastImport)
        try container.encode(importConcurrency, forKey: .importConcurrency)
        try container.encode(largeFileWarningMB, forKey: .largeFileWarningMB)
        try container.encode(storageExceedPolicy, forKey: .storageExceedPolicy)
        try container.encode(defaultDeviceSort, forKey: .defaultDeviceSort)
        try container.encode(rememberLastAppMode, forKey: .rememberLastAppMode)
        try container.encode(lastAppMode, forKey: .lastAppMode)
        try container.encode(fileManagerMacMode, forKey: .fileManagerMacMode)
        try container.encodeIfPresent(fileManagerLastFolderPath, forKey: .fileManagerLastFolderPath)
    }

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
