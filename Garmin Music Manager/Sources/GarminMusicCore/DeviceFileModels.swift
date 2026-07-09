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
    /// Object ID of an existing device file this upload replaces. The helper
    /// deletes it immediately before sending the replacement, so a failed batch
    /// never leaves earlier tracks deleted without their replacements.
    public var replaceObjectID: String?
    /// Optional client-side stable ID (e.g. Mac queue track UUID) for retry mapping.
    /// Not used by the helper; ignored if missing on older payloads.
    public var clientTrackID: String?

    public init(
        localPath: String,
        remotePath: String,
        displayName: String,
        metadata: DeviceAudioMetadata? = nil,
        replaceObjectID: String? = nil,
        clientTrackID: String? = nil
    ) {
        self.localPath = localPath
        self.remotePath = remotePath
        self.displayName = displayName
        self.metadata = metadata
        self.replaceObjectID = replaceObjectID
        self.clientTrackID = clientTrackID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localPath = try container.decode(String.self, forKey: .localPath)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        displayName = try container.decode(String.self, forKey: .displayName)
        metadata = try container.decodeIfPresent(DeviceAudioMetadata.self, forKey: .metadata)
        replaceObjectID = try container.decodeIfPresent(String.self, forKey: .replaceObjectID)
        clientTrackID = try container.decodeIfPresent(String.self, forKey: .clientTrackID)
    }

    public var clientTrackUUID: UUID? {
        clientTrackID.flatMap(UUID.init(uuidString:))
    }
}

/// One successfully uploaded object, as reported by the helper.
/// Used to build native playlists without a full post-sync library re-list.
public struct DeviceUploadedObject: Codable, Hashable {
    public var displayName: String
    public var remotePath: String
    public var size: Int64
    public var objectID: String?

    public init(
        displayName: String,
        remotePath: String,
        size: Int64,
        objectID: String? = nil
    ) {
        self.displayName = displayName
        self.remotePath = remotePath
        self.size = size
        self.objectID = objectID
    }
}

public struct DeviceFileOperationResult: Codable, Hashable {
    public var completedCount: Int
    public var failedItems: [String]
    public var message: String?
    /// Populated for upload operations when the helper returns object IDs.
    public var uploadedFiles: [DeviceUploadedObject]

    public init(
        completedCount: Int,
        failedItems: [String] = [],
        message: String? = nil,
        uploadedFiles: [DeviceUploadedObject] = []
    ) {
        self.completedCount = completedCount
        self.failedItems = failedItems
        self.message = message
        self.uploadedFiles = uploadedFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completedCount = try container.decode(Int.self, forKey: .completedCount)
        failedItems = try container.decodeIfPresent([String].self, forKey: .failedItems) ?? []
        message = try container.decodeIfPresent(String.self, forKey: .message)
        uploadedFiles = try container.decodeIfPresent([DeviceUploadedObject].self, forKey: .uploadedFiles) ?? []
    }
}

public struct DeviceOperation: Identifiable, Codable, Hashable {
    public var id: UUID
    public var kind: DeviceOperationKind
    public var phase: String
    public var progress: Double?
    public var canCancel: Bool
    public var lastError: String?
    /// Zero-based current item when known (MTP transfer events).
    public var itemIndex: Int?
    public var itemCount: Int?
    public var itemName: String?

    public init(
        id: UUID = UUID(),
        kind: DeviceOperationKind,
        phase: String,
        progress: Double? = nil,
        canCancel: Bool = false,
        lastError: String? = nil,
        itemIndex: Int? = nil,
        itemCount: Int? = nil,
        itemName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.progress = progress
        self.canCancel = canCancel
        self.lastError = lastError
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.itemName = itemName
    }

    /// "3 of 12 · Song.mp3" when structured indices are present.
    public var itemLabel: String? {
        guard let itemCount, itemCount > 0, let itemIndex else {
            if let itemName, !itemName.isEmpty { return itemName }
            return nil
        }
        let n = min(itemIndex + 1, itemCount)
        if let itemName, !itemName.isEmpty {
            return "\(n) of \(itemCount) · \(itemName)"
        }
        return "\(n) of \(itemCount)"
    }

    public var primaryLine: String {
        if let itemLabel { return itemLabel }
        return phase
    }
}
