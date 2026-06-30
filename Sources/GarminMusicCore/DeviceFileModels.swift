import Foundation

public enum DeviceBackendKind: String, Codable, Hashable, CaseIterable {
    case mountedFolder
    case mtp
}

public enum DeviceFileType: String, Codable, Hashable, CaseIterable {
    case audio
    case playlist
    case folder
    case other
}

public enum DeviceCollectionKind: String, Codable, Hashable, CaseIterable {
    case allMusic
    case playlist
    case album
    case folder
}

public enum DeviceBrowseMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case musicOnly
    case advancedStorage

    public var id: String { rawValue }
}

public enum DestructiveConfirmationMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case always
    case batchesOnly
    case never

    public var id: String { rawValue }
}

public enum DeviceOperationKind: String, Codable, Hashable, CaseIterable {
    case copy
    case upload
    case delete
    case move
    case sync
    case refresh
}

public struct DeviceAudioMetadata: Codable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationSeconds: Double?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
    }
}

public struct DeviceFile: Identifiable, Codable, Hashable {
    public var id: String {
        let stablePart = objectID ?? path
        return "\(backendKind.rawValue):\(stablePart)"
    }

    public var objectID: String?
    public var name: String
    public var type: DeviceFileType
    public var size: Int64
    public var parentID: String?
    public var path: String
    public var backendKind: DeviceBackendKind
    public var modifiedDate: Date?
    public var audioMetadata: DeviceAudioMetadata?

    public init(
        objectID: String?,
        name: String,
        type: DeviceFileType,
        size: Int64,
        parentID: String? = nil,
        path: String,
        backendKind: DeviceBackendKind,
        modifiedDate: Date? = nil,
        audioMetadata: DeviceAudioMetadata? = nil
    ) {
        self.objectID = objectID
        self.name = name
        self.type = type
        self.size = size
        self.parentID = parentID
        self.path = path
        self.backendKind = backendKind
        self.modifiedDate = modifiedDate
        self.audioMetadata = audioMetadata
    }

    public var locationDescription: String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." || parent == "/" {
            return type == .audio ? "Music" : "Root"
        }
        return parent
    }

    public var isInMusicArea: Bool {
        let lowerPath = path.lowercased()
        return type == .audio
            || lowerPath.hasPrefix("music/")
            || lowerPath.contains("/music/")
            || lowerPath.hasPrefix("garmin/music/")
    }
}

public struct DeviceCollection: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var kind: DeviceCollectionKind
    public var fileIDs: [String]
    public var unmatchedItems: [String]

    public init(
        id: String,
        name: String,
        kind: DeviceCollectionKind,
        fileIDs: [String],
        unmatchedItems: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fileIDs = fileIDs
        self.unmatchedItems = unmatchedItems
    }

    public var totalItemCount: Int {
        fileIDs.count + unmatchedItems.count
    }
}

public struct DeviceStorageInfo: Codable, Hashable {
    public var totalCapacity: Int64?
    public var availableCapacity: Int64?
    public var usedByFiles: Int64
    public var fileCount: Int

    public init(
        totalCapacity: Int64?,
        availableCapacity: Int64?,
        usedByFiles: Int64,
        fileCount: Int
    ) {
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.usedByFiles = usedByFiles
        self.fileCount = fileCount
    }
}

public struct DeviceFileSystemSnapshot: Codable, Hashable {
    public var files: [DeviceFile]
    public var collections: [DeviceCollection]
    public var storageInfo: DeviceStorageInfo?
    public var deviceName: String?
    public var diagnosticMessage: String?

    public init(
        files: [DeviceFile],
        collections: [DeviceCollection],
        storageInfo: DeviceStorageInfo?,
        deviceName: String?,
        diagnosticMessage: String?
    ) {
        self.files = files
        self.collections = collections
        self.storageInfo = storageInfo
        self.deviceName = deviceName
        self.diagnosticMessage = diagnosticMessage
    }
}

public struct DeviceUploadFile: Codable, Hashable {
    public var localPath: String
    public var remotePath: String
    public var displayName: String
    public var metadata: DeviceAudioMetadata?

    public init(
        localPath: String,
        remotePath: String,
        displayName: String,
        metadata: DeviceAudioMetadata? = nil
    ) {
        self.localPath = localPath
        self.remotePath = remotePath
        self.displayName = displayName
        self.metadata = metadata
    }
}

public struct DeviceFileOperationResult: Codable, Hashable {
    public var completedCount: Int
    public var failedItems: [String]
    public var message: String?

    public init(completedCount: Int, failedItems: [String] = [], message: String? = nil) {
        self.completedCount = completedCount
        self.failedItems = failedItems
        self.message = message
    }
}

public struct DeviceOperation: Identifiable, Codable, Hashable {
    public var id: UUID
    public var kind: DeviceOperationKind
    public var phase: String
    public var progress: Double?
    public var canCancel: Bool
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        kind: DeviceOperationKind,
        phase: String,
        progress: Double? = nil,
        canCancel: Bool = false,
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.progress = progress
        self.canCancel = canCancel
        self.lastError = lastError
    }
}
