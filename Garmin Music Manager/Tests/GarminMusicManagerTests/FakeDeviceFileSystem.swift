import Foundation
import GarminMusicCore
@testable import GarminMusicManager

/// Scriptable `DeviceFileSystem` for store/coordinator tests (no USB).
final class FakeDeviceFileSystem: DeviceFileSystem, @unchecked Sendable {
    let deviceID: String
    let displayName: String
    let backendKind: DeviceBackendKind
    let supportsMove: Bool

    var listMusicSnapshot: DeviceFileSystemSnapshot
    var listStorageSnapshot: DeviceFileSystemSnapshot?

    /// FIFO of upload outcomes. Each call to `upload` consumes one entry.
    var uploadResults: [Result<DeviceFileOperationResult, Error>] = []
    var createPlaylistResults: [Result<DeviceFileOperationResult, Error>] = []

    private(set) var uploadCallCount = 0
    private(set) var lastUploadFiles: [DeviceUploadFile] = []
    private(set) var listMusicCallCount = 0
    private(set) var createPlaylistCallCount = 0
    private(set) var lastPlaylistName: String?

    /// Progress events emitted once per upload call (before returning the result).
    var progressEventsPerUpload: [MTPProgressEvent] = []

    init(
        deviceID: String = "fake-mtp",
        displayName: String = "Fake Garmin",
        backendKind: DeviceBackendKind = .mtp,
        supportsMove: Bool = false,
        listMusicSnapshot: DeviceFileSystemSnapshot = DeviceFileSystemSnapshot(
            files: [],
            collections: [],
            storageInfo: DeviceStorageInfo(totalCapacity: 1_000_000_000, availableCapacity: 500_000_000, usedByFiles: 0, fileCount: 0),
            deviceName: "Fake Garmin",
            diagnosticMessage: nil
        )
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.backendKind = backendKind
        self.supportsMove = supportsMove
        self.listMusicSnapshot = listMusicSnapshot
        self.listStorageSnapshot = nil
    }

    func listMusic() async throws -> DeviceFileSystemSnapshot {
        listMusicCallCount += 1
        return listMusicSnapshot
    }

    func listStorageTree() async throws -> DeviceFileSystemSnapshot {
        listMusicCallCount += 1
        return listStorageSnapshot ?? listMusicSnapshot
    }

    func download(
        _ files: [DeviceFile],
        to destinationFolder: URL,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult {
        throw DeviceFileSystemError.unsupported("Fake download not configured.")
    }

    func upload(
        _ files: [DeviceUploadFile],
        syncSettings: SyncSettings?,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult {
        _ = syncSettings
        uploadCallCount += 1
        lastUploadFiles = files
        for event in progressEventsPerUpload {
            onProgress?(event)
        }
        guard !uploadResults.isEmpty else {
            // Default: all succeed with synthetic object IDs.
            let uploaded = files.enumerated().map { index, file in
                DeviceUploadedObject(
                    displayName: file.displayName,
                    remotePath: file.remotePath,
                    size: 1,
                    objectID: "oid-\(index)"
                )
            }
            return DeviceFileOperationResult(
                completedCount: files.count,
                failedItems: [],
                message: "\(files.count) file(s) uploaded.",
                uploadedFiles: uploaded
            )
        }
        let next = uploadResults.removeFirst()
        return try next.get()
    }

    func delete(_ files: [DeviceFile]) async throws -> DeviceFileOperationResult {
        DeviceFileOperationResult(completedCount: files.count, failedItems: [], message: "\(files.count) file(s) deleted.")
    }

    func move(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult {
        throw DeviceFileSystemError.unsupported("Fake move not supported.")
    }

    func storageInfo() async throws -> DeviceStorageInfo? {
        listMusicSnapshot.storageInfo
    }

    func createPlaylist(name: String, tracks: [DeviceFile]) async throws -> DeviceFileOperationResult {
        createPlaylistCallCount += 1
        lastPlaylistName = name
        if !createPlaylistResults.isEmpty {
            return try createPlaylistResults.removeFirst().get()
        }
        return DeviceFileOperationResult(
            completedCount: 1,
            failedItems: [],
            message: "Playlist “\(name)” created with \(tracks.count) track(s)."
        )
    }
}
