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
    /// Create a native MTP playlist from track object IDs (`files[].objectID`).
    case createPlaylist
}

public struct MTPHelperRequest: Codable, Hashable {
    public var operation: MTPHelperOperation
    public var files: [DeviceFile]
    public var uploadFiles: [DeviceUploadFile]
    public var destinationPath: String?
    public var browseMode: DeviceBrowseMode
    /// Playlist display name for `.createPlaylist`.
    public var playlistName: String?

    public init(
        operation: MTPHelperOperation,
        files: [DeviceFile] = [],
        uploadFiles: [DeviceUploadFile] = [],
        destinationPath: String? = nil,
        browseMode: DeviceBrowseMode = .musicOnly,
        playlistName: String? = nil
    ) {
        self.operation = operation
        self.files = files
        self.uploadFiles = uploadFiles
        self.destinationPath = destinationPath
        self.browseMode = browseMode
        self.playlistName = playlistName
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

/// Byte/item progress emitted as NDJSON lines **before** the final `MTPHelperResponse`.
///
/// Stream framing (serve mode):
/// ```text
/// {"progress":{...}}\n
/// {"progress":{...}}\n
/// {"ok":true,"operationResult":{...}}\n
/// ```
public struct MTPProgressEvent: Codable, Hashable, Sendable {
    public var phase: String
    /// Zero-based index of the current item within this helper request.
    public var itemIndex: Int
    public var itemCount: Int
    public var itemName: String?
    public var bytesTransferred: Int64?
    public var bytesTotal: Int64?
    /// 0...1 for the whole helper request (all items in the current batch).
    public var overallFraction: Double
    public var message: String?

    public init(
        phase: String,
        itemIndex: Int,
        itemCount: Int,
        itemName: String? = nil,
        bytesTransferred: Int64? = nil,
        bytesTotal: Int64? = nil,
        overallFraction: Double,
        message: String? = nil
    ) {
        self.phase = phase
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.itemName = itemName
        self.bytesTransferred = bytesTransferred
        self.bytesTotal = bytesTotal
        self.overallFraction = min(1, max(0, overallFraction))
        self.message = message
    }

    public var displayMessage: String {
        if let message, !message.isEmpty { return message }
        if let itemName, !itemName.isEmpty {
            return "\(phase.capitalized) \(itemIndex + 1)/\(max(itemCount, 1)): \(itemName)"
        }
        return "\(phase.capitalized) \(itemIndex + 1)/\(max(itemCount, 1))"
    }
}

/// Wire format for one NDJSON line from the helper (progress **or** final result).
public struct MTPHelperStreamLine: Codable, Hashable {
    public var progress: MTPProgressEvent?
    public var ok: Bool?
    public var snapshot: DeviceFileSystemSnapshot?
    public var operationResult: DeviceFileOperationResult?
    public var dependencyStatus: MTPToolStatus?
    public var error: MTPHelperError?

    public init(
        progress: MTPProgressEvent? = nil,
        ok: Bool? = nil,
        snapshot: DeviceFileSystemSnapshot? = nil,
        operationResult: DeviceFileOperationResult? = nil,
        dependencyStatus: MTPToolStatus? = nil,
        error: MTPHelperError? = nil
    ) {
        self.progress = progress
        self.ok = ok
        self.snapshot = snapshot
        self.operationResult = operationResult
        self.dependencyStatus = dependencyStatus
        self.error = error
    }

    public var isProgressOnly: Bool {
        progress != nil
            && ok == nil
            && snapshot == nil
            && operationResult == nil
            && dependencyStatus == nil
            && error == nil
    }

    public var asResponse: MTPHelperResponse? {
        guard !isProgressOnly else { return nil }
        if let ok {
            return MTPHelperResponse(
                ok: ok,
                snapshot: snapshot,
                operationResult: operationResult,
                dependencyStatus: dependencyStatus,
                error: error
            )
        }
        // Progress-less error-only / result-only lines.
        if error != nil || operationResult != nil || snapshot != nil || dependencyStatus != nil {
            return MTPHelperResponse(
                ok: error == nil,
                snapshot: snapshot,
                operationResult: operationResult,
                dependencyStatus: dependencyStatus,
                error: error
            )
        }
        return nil
    }

    public static func progressLine(_ event: MTPProgressEvent) -> MTPHelperStreamLine {
        MTPHelperStreamLine(progress: event)
    }
}

/// Encodes a progress-only stream line as NDJSON (no trailing newline).
public enum MTPProgressLineEncoder {
    public static func encode(_ event: MTPProgressEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(MTPHelperStreamLine.progressLine(event))
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
