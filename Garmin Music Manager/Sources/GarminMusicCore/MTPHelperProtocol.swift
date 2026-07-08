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
    /// Raw libmtp/libusb error text, kept out of the user-facing message.
    public var diagnosticDetail: String?

    public init(code: String, message: String, recoverySuggestion: String? = nil, diagnosticDetail: String? = nil) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.diagnosticDetail = diagnosticDetail
    }

    public var errorDescription: String? {
        if let recoverySuggestion, !recoverySuggestion.isEmpty {
            return "\(message) \(recoverySuggestion)"
        }
        return message
    }
}

public struct MTPToolStatus: Codable, Hashable {
    public var connectionBackend: String?
    public var libmtpVersion: String?
    public var libmtpLibraryPath: String?
    public var libmtpHeaderPath: String?
    public var mtpDetectPath: String?
    public var mtpTracksPath: String?
    public var mtpFilesPath: String?
    public var mtpPlaylistsPath: String?
    public var mtpGetFilePath: String?
    public var mtpDeleteFilePath: String?
    public var mtpSendFilePath: String?
    public var mtpSendTrackPath: String?

    public init(
        connectionBackend: String? = nil,
        libmtpVersion: String? = nil,
        libmtpLibraryPath: String? = nil,
        libmtpHeaderPath: String? = nil,
        mtpDetectPath: String? = nil,
        mtpTracksPath: String? = nil,
        mtpFilesPath: String? = nil,
        mtpPlaylistsPath: String? = nil,
        mtpGetFilePath: String? = nil,
        mtpDeleteFilePath: String? = nil,
        mtpSendFilePath: String? = nil,
        mtpSendTrackPath: String? = nil
    ) {
        self.connectionBackend = connectionBackend
        self.libmtpVersion = libmtpVersion
        self.libmtpLibraryPath = libmtpLibraryPath
        self.libmtpHeaderPath = libmtpHeaderPath
        self.mtpDetectPath = mtpDetectPath
        self.mtpTracksPath = mtpTracksPath
        self.mtpFilesPath = mtpFilesPath
        self.mtpPlaylistsPath = mtpPlaylistsPath
        self.mtpGetFilePath = mtpGetFilePath
        self.mtpDeleteFilePath = mtpDeleteFilePath
        self.mtpSendFilePath = mtpSendFilePath
        self.mtpSendTrackPath = mtpSendTrackPath
    }

    public var usesDirectLibMTP: Bool {
        connectionBackend == "direct-libmtp" || libmtpVersion != nil
    }

    public var canDetect: Bool {
        usesDirectLibMTP || mtpDetectPath != nil
    }

    public var canListMusic: Bool {
        usesDirectLibMTP || mtpTracksPath != nil || mtpFilesPath != nil
    }

    public var canDownload: Bool {
        usesDirectLibMTP || mtpGetFilePath != nil
    }

    public var canDelete: Bool {
        usesDirectLibMTP || mtpDeleteFilePath != nil
    }

    public var canUpload: Bool {
        usesDirectLibMTP || mtpSendTrackPath != nil || mtpSendFilePath != nil
    }

    public var isReady: Bool {
        usesDirectLibMTP || (canDetect && canListMusic && canUpload)
    }
}
