import Foundation

public enum MTPHelperOperation: String, Codable, Hashable {
    case status
    case detect
    case listMusic
    case listStorageTree
    case download
    case upload
    case delete
    case move
    case storageInfo
}

public struct MTPHelperRequest: Codable, Hashable {
    public var operation: MTPHelperOperation
    public var files: [DeviceFile]
    public var uploadFiles: [DeviceUploadFile]
    public var destinationPath: String?
    public var browseMode: DeviceBrowseMode

    public init(
        operation: MTPHelperOperation,
        files: [DeviceFile] = [],
        uploadFiles: [DeviceUploadFile] = [],
        destinationPath: String? = nil,
        browseMode: DeviceBrowseMode = .musicOnly
    ) {
        self.operation = operation
        self.files = files
        self.uploadFiles = uploadFiles
        self.destinationPath = destinationPath
        self.browseMode = browseMode
    }
}

public struct MTPHelperResponse: Codable, Hashable {
    public var ok: Bool
    public var snapshot: DeviceFileSystemSnapshot?
    public var operationResult: DeviceFileOperationResult?
    public var dependencyStatus: MTPToolStatus?
    public var error: MTPHelperError?

    public init(
        ok: Bool,
        snapshot: DeviceFileSystemSnapshot? = nil,
        operationResult: DeviceFileOperationResult? = nil,
        dependencyStatus: MTPToolStatus? = nil,
        error: MTPHelperError? = nil
    ) {
        self.ok = ok
        self.snapshot = snapshot
        self.operationResult = operationResult
        self.dependencyStatus = dependencyStatus
        self.error = error
    }
}

public struct MTPHelperError: Codable, Hashable, LocalizedError {
    public var code: String
    public var message: String
    public var recoverySuggestion: String?

    public init(code: String, message: String, recoverySuggestion: String? = nil) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }

    public var errorDescription: String? {
        if let recoverySuggestion, !recoverySuggestion.isEmpty {
            return "\(message) \(recoverySuggestion)"
        }
        return message
    }
}

public struct MTPToolStatus: Codable, Hashable {
    public var mtpDetectPath: String?
    public var mtpTracksPath: String?
    public var mtpFilesPath: String?
    public var mtpPlaylistsPath: String?
    public var mtpGetFilePath: String?
    public var mtpDeleteFilePath: String?
    public var mtpSendFilePath: String?
    public var mtpSendTrackPath: String?

    public init(
        mtpDetectPath: String?,
        mtpTracksPath: String?,
        mtpFilesPath: String?,
        mtpPlaylistsPath: String?,
        mtpGetFilePath: String?,
        mtpDeleteFilePath: String?,
        mtpSendFilePath: String?,
        mtpSendTrackPath: String?
    ) {
        self.mtpDetectPath = mtpDetectPath
        self.mtpTracksPath = mtpTracksPath
        self.mtpFilesPath = mtpFilesPath
        self.mtpPlaylistsPath = mtpPlaylistsPath
        self.mtpGetFilePath = mtpGetFilePath
        self.mtpDeleteFilePath = mtpDeleteFilePath
        self.mtpSendFilePath = mtpSendFilePath
        self.mtpSendTrackPath = mtpSendTrackPath
    }

    public var canDetect: Bool {
        mtpDetectPath != nil
    }

    public var canListMusic: Bool {
        mtpTracksPath != nil || mtpFilesPath != nil
    }

    public var canDownload: Bool {
        mtpGetFilePath != nil
    }

    public var canDelete: Bool {
        mtpDeleteFilePath != nil
    }

    public var canUpload: Bool {
        mtpSendTrackPath != nil || mtpSendFilePath != nil
    }

    public var isReady: Bool {
        canDetect && canListMusic && canUpload
    }
}
