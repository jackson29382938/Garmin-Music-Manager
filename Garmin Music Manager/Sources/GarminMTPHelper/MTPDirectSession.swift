import CLibMTP
import Darwin
import Foundation
import GarminMusicCore

final class MTPDirectSession {
    static let garminVendorID: UInt16 = 0x091e
    private static let rootFolderID: UInt32 = LIBMTP_FILES_AND_FOLDERS_ROOT
    private static let supportedAudioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "alac"]
    private static let supportedPlaylistExtensions: Set<String> = ["m3u", "m3u8", "pls"]

    private let device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>
    private let rawDevice: RawDeviceDescriptor
    private let fileManager: FileManager
    private var lastStorageResult: Int32?
    /// Folder tree is expensive on Garmin; cache across uploads within a session.
    private var cachedFolderIndex: MTPFolderIndex?
    /// Full music listing is very expensive; reuse within a warm session until a write.
    private var cachedMusicSnapshot: DeviceFileSystemSnapshot?
    /// Whether `cachedMusicSnapshot` included on-device M3U body downloads.
    private var cachedMusicSnapshotIncludesPlaylistContents = false
    /// Optional NDJSON progress sink (set by the runner in serve/one-shot modes).
    var progressReporter: MTPProgressReporter?

    private init(
        device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>,
        rawDevice: RawDeviceDescriptor,
        fileManager: FileManager
    ) {
        self.device = device
        self.rawDevice = rawDevice
        self.fileManager = fileManager
        refreshStorage()
    }

    deinit {
        LIBMTP_Release_Device(device)
    }

    static func open(fileManager: FileManager) throws -> MTPDirectSession {
        LIBMTP_Init()
        LIBMTP_Set_Debug(LIBMTP_DEBUG_NONE)

        let opened = try MTPRetryPolicy.runWithRetry {
            try openOnce(fileManager: fileManager)
        }
        return opened
    }

    private static func openOnce(fileManager: FileManager) throws -> MTPDirectSession {
        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var deviceCount: Int32 = 0

        let detectResult = LIBMTP_Detect_Raw_Devices(&rawDevices, &deviceCount)
        defer {
            if let rawDevices {
                LIBMTP_FreeMemory(UnsafeMutableRawPointer(rawDevices))
            }
        }

        guard detectResult == LIBMTP_ERROR_NONE else {
            throw error(forDetectionResult: detectResult)
        }
        guard let rawDevices, deviceCount > 0 else {
            throw noDeviceError()
        }

        let descriptors = (0..<Int(deviceCount)).map { index in
            RawDeviceDescriptor(rawDevices[index], index: index)
        }
        guard let selected = descriptors.first(where: \.isGarmin) else {
            throw MTPHelperError(
                code: "no-garmin-mtp-device",
                message: "MTP devices are visible, but none identify as a Garmin watch.",
                recoverySuggestion: "Disconnect other MTP devices, connect the Garmin with a data USB cable, wake it, then refresh."
            )
        }

        // Prefer cached open. On Garmin watches (e.g. Forerunner 955 + libmtp 1.1.x),
        // Open_Raw_Device_Uncached often returns a live session whose Get_Filelisting /
        // Get_Tracklisting are empty, while the cached open returns the full library.
        let rawPointer = rawDevices.advanced(by: selected.index)
        let opened = LIBMTP_Open_Raw_Device(rawPointer)
            ?? LIBMTP_Open_Raw_Device_Uncached(rawPointer)
        guard let opened else {
            throw busyError(rawDevice: selected, details: [])
        }

        return MTPDirectSession(device: opened, rawDevice: selected, fileManager: fileManager)
    }

    func detectionSnapshot() -> DeviceFileSystemSnapshot {
        DeviceFileSystemSnapshot(
            files: [],
            collections: [],
            storageInfo: storageInfo(files: []),
            deviceName: deviceDisplayName(),
            diagnosticMessage: "Garmin MTP connection opened with direct libmtp."
        )
    }

    func musicSnapshot(includePlaylistContents: Bool = false) throws -> DeviceFileSystemSnapshot {
        // Reuse a warm-session listing when it already has at least the detail level requested.
        if let cachedMusicSnapshot,
           cachedMusicSnapshotIncludesPlaylistContents || !includePlaylistContents {
            return cachedMusicSnapshot
        }

        refreshStorage()
        let fileRecords = try loadFileRecords()
        let pathsByID = buildPathsByID(from: fileRecords)
        let trackRecords = loadTrackRecords()
        let tracksByID = Dictionary(trackRecords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let playlistRecords = loadPlaylistRecords()
        let playlistTrackIDs = Set(playlistRecords.flatMap(\.trackIDs))

        var seenObjectIDs: Set<UInt32> = []
        var files = fileRecords.compactMap { record -> DeviceFile? in
            let path = pathsByID[record.id] ?? record.name
            guard shouldExposeAsMusic(record, path: path, playlistTrackIDs: playlistTrackIDs) else { return nil }
            seenObjectIDs.insert(record.id)
            return deviceFile(
                from: record,
                path: path,
                metadata: tracksByID[record.id]?.metadata,
                typeOverride: .audio
            )
        }

        for track in tracksByID.values where !seenObjectIDs.contains(track.id) {
            files.append(deviceFile(from: track, pathsByID: pathsByID))
        }

        let knownFileIDs = Set(files.compactMap { file in
            file.objectID.flatMap(UInt32.init)
        })
        for trackID in playlistTrackIDs.subtracting(knownFileIDs).sorted() {
            files.append(placeholderPlaylistFile(trackID: trackID, playlists: playlistRecords))
        }

        files.sort {
            let lhsPath = $0.path.isEmpty ? $0.name : $0.path
            let rhsPath = $1.path.isEmpty ? $1.name : $1.path
            return lhsPath.localizedCaseInsensitiveCompare(rhsPath) == .orderedAscending
        }

        // On-device .m3u/.m3u8 downloads are expensive over MTP; skip unless requested.
        let m3uCollections: [DeviceCollection]
        if includePlaylistContents {
            m3uCollections = loadM3UPlaylistCollections(
                from: fileRecords,
                audioFiles: files
            )
        } else {
            m3uCollections = []
        }

        let collections = musicCollections(
            for: files,
            playlists: playlistRecords,
            m3uPlaylists: m3uCollections,
            knownFileIDs: Set(files.map(\.id))
        )

        let info = storageInfo(files: files)
        let playlistCollectionCount = collections.filter { $0.kind == .playlist }.count
        let messages = [
            musicDiagnostic(
                files: files,
                rawFileCount: fileRecords.count,
                trackCount: trackRecords.count,
                playlistCount: max(playlistRecords.count, playlistCollectionCount),
                playlistTrackCount: playlistTrackIDs.count
            ),
            storageDiagnostic(info)
        ].compactMap { $0 }
        let snapshot = DeviceFileSystemSnapshot(
            files: files,
            collections: collections,
            storageInfo: info,
            deviceName: deviceDisplayName(),
            diagnosticMessage: messages.isEmpty ? nil : messages.joined(separator: " ")
        )
        cachedMusicSnapshot = snapshot
        cachedMusicSnapshotIncludesPlaylistContents = includePlaylistContents
        return snapshot
    }

    private func invalidateListingCaches() {
        cachedMusicSnapshot = nil
        cachedMusicSnapshotIncludesPlaylistContents = false
    }

    func storageSnapshot() throws -> DeviceFileSystemSnapshot {
        refreshStorage()
        let records = try loadFileRecords()
        let pathsByID = buildPathsByID(from: records)
        let files = records
            .map { record in
                deviceFile(
                    from: record,
                    path: pathsByID[record.id] ?? record.name,
                    metadata: nil
                )
            }
            .sorted {
                if $0.type == .folder, $1.type != .folder { return true }
                if $0.type != .folder, $1.type == .folder { return false }
                return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }

        let info = storageInfo(files: files)
        return DeviceFileSystemSnapshot(
            files: files,
            collections: [
                DeviceCollection(
                    id: "all-storage",
                    name: "All Storage",
                    kind: .folder,
                    fileIDs: files.map(\.id)
                )
            ],
            storageInfo: info,
            deviceName: deviceDisplayName(),
            diagnosticMessage: storageDiagnostic(info)
        )
    }

    func download(_ files: [DeviceFile], to destinationPath: String?) throws -> DeviceFileOperationResult {
        guard let destinationPath, !destinationPath.isEmpty else {
            throw MTPHelperError(code: "missing-destination", message: "Choose a destination folder on this Mac.")
        }

        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var copied = 0
        var failures: [String] = []
        let itemCount = files.count
        let totalBatchBytes = files.reduce(Int64(0)) { $0 + max($1.size, 0) }
        var completedBytes: Int64 = 0

        for (index, file) in files.enumerated() {
            try MTPCancelState.throwIfCancelled()

            guard let objectID = UInt32(file.objectID ?? "") else {
                failures.append(file.name)
                continue
            }

            let target = uniqueURL(
                in: destination,
                preferredFileName: sanitizedFileName(file.name, fallback: "Garmin Track")
            )

            let itemBytes = max(file.size, 0)
            progressReporter?.itemStarted(
                phase: "download",
                itemIndex: index,
                itemCount: itemCount,
                itemName: file.name,
                bytesTotal: itemBytes > 0 ? itemBytes : nil,
                completedBytesBeforeItem: completedBytes,
                totalBatchBytes: totalBatchBytes
            )

            let bridge = progressReporter?.makeBridge(
                phase: "download",
                itemIndex: index,
                itemCount: itemCount,
                itemName: file.name,
                itemBytes: itemBytes,
                completedBytesBeforeItem: completedBytes,
                totalBatchBytes: totalBatchBytes
            )

            do {
                try MTPRetryPolicy.runWithRetry {
                    try self.downloadSingleFile(file, objectID: objectID, to: target, progressBridge: bridge)
                }
                copied += 1
                completedBytes += itemBytes
                progressReporter?.itemFinished(
                    phase: "download",
                    itemIndex: index,
                    itemCount: itemCount,
                    itemName: file.name,
                    bytesTotal: itemBytes > 0 ? itemBytes : nil,
                    completedBytesBeforeItem: completedBytes - itemBytes,
                    totalBatchBytes: totalBatchBytes
                )
            } catch {
                failures.append(file.name)
            }
        }

        return DeviceFileOperationResult(
            completedCount: copied,
            failedItems: failures,
            message: resultMessage(action: "copied", count: copied, failures: failures.count)
        )
    }

    func upload(_ uploadFiles: [DeviceUploadFile]) throws -> DeviceFileOperationResult {
        var uploaded = 0
        var failures: [String] = []
        var successfulUploads: [MTPUploadedFile] = []
        var folderIndex = try folderIndexCached()
        let itemCount = uploadFiles.count
        let totalBatchBytes = uploadFiles.reduce(Int64(0)) { partial, file in
            partial + max(fileSize(at: URL(fileURLWithPath: file.localPath)), 0)
        }
        var completedBytes: Int64 = 0

        for (index, uploadFile) in uploadFiles.enumerated() {
            try MTPCancelState.throwIfCancelled()

            let localURL = URL(fileURLWithPath: uploadFile.localPath)
            guard fileManager.fileExists(atPath: localURL.path), fileSize(at: localURL) > 0 else {
                failures.append(uploadFile.displayName)
                continue
            }
            let expectedRemotePath = normalizedUploadPath(
                uploadFile.remotePath,
                fallbackFileName: localURL.lastPathComponent
            )
            let expectedSize = fileSize(at: localURL)

            // Replacing: remove the old copy only now that the local file is
            // validated, so a failure earlier in the batch never leaves files
            // deleted without their replacements. Skip the upload if the stale
            // copy cannot be removed — uploading beside it would collide.
            if let replaceID = uploadFile.replaceObjectID.flatMap(UInt32.init) {
                do {
                    try MTPRetryPolicy.runWithRetry {
                        try self.deleteSingleObject(objectID: replaceID, name: uploadFile.displayName)
                    }
                } catch {
                    failures.append(uploadFile.displayName)
                    continue
                }
            }

            progressReporter?.itemStarted(
                phase: "upload",
                itemIndex: index,
                itemCount: itemCount,
                itemName: uploadFile.displayName,
                bytesTotal: expectedSize,
                completedBytesBeforeItem: completedBytes,
                totalBatchBytes: totalBatchBytes
            )

            let bridge = progressReporter?.makeBridge(
                phase: "upload",
                itemIndex: index,
                itemCount: itemCount,
                itemName: uploadFile.displayName,
                itemBytes: expectedSize,
                completedBytesBeforeItem: completedBytes,
                totalBatchBytes: totalBatchBytes
            )

            do {
                var objectID: UInt32?
                try MTPRetryPolicy.runWithRetry {
                    objectID = try self.uploadSingleFile(
                        uploadFile,
                        localURL: localURL,
                        folderIndex: &folderIndex,
                        progressBridge: bridge
                    )
                }
                cachedFolderIndex = folderIndex
                uploaded += 1
                completedBytes += expectedSize
                successfulUploads.append(MTPUploadedFile(
                    displayName: uploadFile.displayName,
                    remotePath: expectedRemotePath,
                    size: expectedSize,
                    objectID: objectID
                ))
                progressReporter?.itemFinished(
                    phase: "upload",
                    itemIndex: index,
                    itemCount: itemCount,
                    itemName: uploadFile.displayName,
                    bytesTotal: expectedSize,
                    completedBytesBeforeItem: completedBytes - expectedSize,
                    totalBatchBytes: totalBatchBytes
                )
            } catch {
                // Folder index may be stale after a mid-batch USB glitch.
                cachedFolderIndex = folderIndex
                failures.append(uploadFile.displayName)
            }
        }

        // Prefer per-object metadata checks (cheap). Full re-list is a last resort
        // and was a major source of multi-minute stalls after large batches.
        let verificationFailures = verifyUploadedFiles(successfulUploads)
        let verifiedUploads: [MTPUploadedFile]
        if verificationFailures.isEmpty {
            verifiedUploads = successfulUploads
        } else {
            let failedNames = Set(verificationFailures)
            failures.append(contentsOf: verificationFailures)
            uploaded = max(0, uploaded - verificationFailures.count)
            verifiedUploads = successfulUploads.filter { !failedNames.contains($0.displayName) }
        }

        if uploaded > 0 {
            invalidateListingCaches()
        }

        let uploadedObjects = verifiedUploads.map { upload in
            DeviceUploadedObject(
                displayName: upload.displayName,
                remotePath: upload.remotePath,
                size: upload.size,
                objectID: upload.objectID.map(String.init)
            )
        }

        return DeviceFileOperationResult(
            completedCount: uploaded,
            failedItems: failures,
            message: resultMessage(action: "uploaded", count: uploaded, failures: failures.count),
            uploadedFiles: uploadedObjects
        )
    }

    func delete(_ files: [DeviceFile]) throws -> DeviceFileOperationResult {
        var deleted = 0
        var failures: [String] = []

        for file in files {
            guard let objectID = UInt32(file.objectID ?? "") else {
                failures.append(file.name)
                continue
            }

            do {
                try MTPRetryPolicy.runWithRetry {
                    try self.deleteSingleObject(objectID: objectID, name: file.name)
                }
                deleted += 1
            } catch {
                failures.append(file.name)
            }
        }

        if deleted > 0 {
            // Deleted objects may have been folders; rebuild on next upload.
            cachedFolderIndex = nil
            invalidateListingCaches()
        }

        return DeviceFileOperationResult(
            completedCount: deleted,
            failedItems: failures,
            message: resultMessage(action: "deleted", count: deleted, failures: failures.count)
        )
    }

    /// Creates a native MTP playlist referencing existing track object IDs.
    func createPlaylist(name: String?, trackFiles: [DeviceFile]) throws -> DeviceFileOperationResult {
        try MTPCancelState.throwIfCancelled()
        let cleanName = (name ?? "Garmin Playlist")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistName = cleanName.isEmpty ? "Garmin Playlist" : sanitizedFileName(cleanName, fallback: "Garmin Playlist")

        var trackIDs: [UInt32] = []
        var failures: [String] = []
        var seen = Set<UInt32>()
        for file in trackFiles {
            guard let objectID = UInt32(file.objectID ?? ""), objectID != 0 else {
                failures.append(file.name)
                continue
            }
            if seen.insert(objectID).inserted {
                trackIDs.append(objectID)
            }
        }

        guard !trackIDs.isEmpty else {
            throw MTPHelperError(
                code: "playlist-empty",
                message: "No track IDs were available to build the playlist \(playlistName)."
            )
        }

        let action = try MTPRetryPolicy.runWithRetry {
            try self.createOrUpdatePlaylistOnce(name: playlistName, trackIDs: trackIDs)
        }

        invalidateListingCaches()

        let verb = action == .updated ? "Updated" : "Created"
        return DeviceFileOperationResult(
            completedCount: trackIDs.count,
            failedItems: failures,
            message: "\(verb) playlist “\(playlistName)” with \(trackIDs.count) track(s)."
        )
    }

    private enum PlaylistWriteAction {
        case created
        case updated
    }

    private func createOrUpdatePlaylistOnce(name: String, trackIDs: [UInt32]) throws -> PlaylistWriteAction {
        // Prefer updating an existing playlist with the same name so re-syncs
        // do not pile up duplicate playlists on the watch.
        let records = loadPlaylistRecords()
        let existingID = MTPPlaylistNameMatch.existingID(
            named: name,
            names: records.map { (id: $0.id, name: $0.name) }
        )
        if let existingID {
            try writePlaylist(name: name, trackIDs: trackIDs, existingID: existingID, update: true)
            return .updated
        }
        try writePlaylist(name: name, trackIDs: trackIDs, existingID: 0, update: false)
        return .created
    }

    private func writePlaylist(name: String, trackIDs: [UInt32], existingID: UInt32, update: Bool) throws {
        // Ownership contract with libmtp (see LIBMTP_destroy_playlist_t):
        // - name must be heap-allocated with strdup/malloc (freed via free())
        // - tracks must be malloc'd (not Swift UnsafeMutablePointer.allocate)
        // - Create/Update copy data to the device; they do not free the struct
        // - destroy frees name + tracks + the playlist node itself (one node only)
        guard let playlist = LIBMTP_new_playlist_t() else {
            throw MTPHelperError(code: "playlist-failed", message: "Could not allocate MTP playlist metadata.")
        }
        defer { LIBMTP_destroy_playlist_t(playlist) }

        playlist.pointee.playlist_id = existingID
        playlist.pointee.parent_id = firstStorageMusicParentID()
        playlist.pointee.storage_id = firstStorageID()
        playlist.pointee.name = duplicatedCString(name)
        playlist.pointee.no_tracks = UInt32(trackIDs.count)
        guard let trackBuffer = mallocTrackIDBuffer(trackIDs) else {
            throw MTPHelperError(code: "memory", message: "Could not allocate playlist track buffer.")
        }
        playlist.pointee.tracks = trackBuffer
        playlist.pointee.next = nil

        let result: Int32
        if update {
            result = LIBMTP_Update_Playlist(device, playlist)
        } else {
            result = LIBMTP_Create_New_Playlist(device, playlist)
        }
        guard result == 0 else {
            throw operationError(
                code: "playlist-failed",
                message: update
                    ? "Could not update the playlist \(name) on the Garmin."
                    : "Could not create the playlist \(name) on the Garmin.",
                details: drainErrorStack()
            )
        }
    }

    /// Allocates a C-compatible `uint32_t` array via `malloc` so
    /// `LIBMTP_destroy_playlist_t` can `free()` it safely.
    private func mallocTrackIDBuffer(_ trackIDs: [UInt32]) -> UnsafeMutablePointer<UInt32>? {
        guard !trackIDs.isEmpty else { return nil }
        let byteCount = MemoryLayout<UInt32>.stride * trackIDs.count
        guard let raw = malloc(byteCount) else {
            return nil
        }
        let buffer = raw.assumingMemoryBound(to: UInt32.self)
        for (index, id) in trackIDs.enumerated() {
            buffer[index] = id
        }
        return buffer
    }

    /// Walk a libmtp singly-linked playlist list and free each node.
    private func destroyPlaylistList(_ head: UnsafeMutablePointer<LIBMTP_playlist_t>?) {
        var current = head
        while let pointer = current {
            let next = pointer.pointee.next
            LIBMTP_destroy_playlist_t(pointer)
            current = next
        }
    }

    /// Walk a libmtp singly-linked track list and free each node.
    private func destroyTrackList(_ head: UnsafeMutablePointer<LIBMTP_track_t>?) {
        var current = head
        while let pointer = current {
            let next = pointer.pointee.next
            LIBMTP_destroy_track_t(pointer)
            current = next
        }
    }

    /// Walk a libmtp singly-linked file list and free each node.
    private func destroyFileList(_ head: UnsafeMutablePointer<LIBMTP_file_t>?) {
        var current = head
        while let pointer = current {
            let next = pointer.pointee.next
            LIBMTP_destroy_file_t(pointer)
            current = next
        }
    }

    /// Prefer Music folder as playlist parent when the device exposes one.
    private func firstStorageMusicParentID() -> UInt32 {
        if let music = (try? folderIndexCached())?.location(path: "Music") {
            return music.id
        }
        let defaultMusic = device.pointee.default_music_folder
        if defaultMusic != 0 {
            return defaultMusic
        }
        return Self.rootFolderID
    }

    private func deleteSingleObject(objectID: UInt32, name: String) throws {
        let result = LIBMTP_Delete_Object(device, objectID)
        guard result == 0 else {
            throw operationError(
                code: "delete-failed",
                message: "Could not delete \(name) from the Garmin.",
                details: drainErrorStack()
            )
        }
    }

    private func loadFileRecords() throws -> [MTPFileRecord] {
        // With_Callback variant is the supported API; NULL progress matches Get_Filelisting.
        guard let head = LIBMTP_Get_Filelisting_With_Callback(device, nil, nil) else {
            let errors = drainErrorStack()
            if errors.isEmpty { return [] }
            throw operationError(
                code: "list-failed",
                message: "The Garmin did not return its file list.",
                details: errors
            )
        }
        // destroy_file_t frees a single node; walk the whole list.
        defer { destroyFileList(head) }

        var records: [MTPFileRecord] = []
        var current: UnsafeMutablePointer<LIBMTP_file_t>? = head
        while let pointer = current {
            let file = pointer.pointee
            if let name = string(from: file.filename), !name.isEmpty {
                records.append(MTPFileRecord(
                    id: file.item_id,
                    parentID: file.parent_id,
                    storageID: file.storage_id,
                    name: name,
                    size: file.filesize,
                    modifiedDate: date(from: file.modificationdate),
                    fileType: file.filetype
                ))
            }
            current = file.next
        }
        return records
    }

    private func loadTrackRecords() -> [MTPTrackRecord] {
        guard let head = LIBMTP_Get_Tracklisting_With_Callback(device, nil, nil) else {
            _ = drainErrorStack()
            return []
        }
        // destroy_track_t frees a single node; walk the whole list.
        defer { destroyTrackList(head) }

        var records: [MTPTrackRecord] = []
        var current: UnsafeMutablePointer<LIBMTP_track_t>? = head
        while let pointer = current {
            let track = pointer.pointee
            let fileName = string(from: track.filename)
                ?? string(from: track.title)
                ?? "Track \(track.item_id)"
            records.append(MTPTrackRecord(
                id: track.item_id,
                parentID: track.parent_id,
                storageID: track.storage_id,
                fileName: fileName,
                size: track.filesize,
                modifiedDate: date(from: track.modificationdate),
                fileType: track.filetype,
                metadata: DeviceAudioMetadata(
                    title: string(from: track.title),
                    artist: string(from: track.artist),
                    album: string(from: track.album),
                    durationSeconds: track.duration > 0 ? Double(track.duration) / 1000 : nil
                )
            ))
            current = track.next
        }
        return records
    }

    private func loadPlaylistRecords() -> [MTPPlaylistRecord] {
        guard let head = LIBMTP_Get_Playlist_List(device) else {
            _ = drainErrorStack()
            return []
        }
        // destroy_playlist_t frees a single node (name + tracks + struct), not the chain.
        defer { destroyPlaylistList(head) }

        var records: [MTPPlaylistRecord] = []
        var current: UnsafeMutablePointer<LIBMTP_playlist_t>? = head
        while let pointer = current {
            let playlist = pointer.pointee
            let name = string(from: playlist.name) ?? "Playlist \(playlist.playlist_id)"
            var trackIDs: [UInt32] = []
            if playlist.no_tracks > 0, let tracks = playlist.tracks {
                for index in 0..<Int(playlist.no_tracks) {
                    trackIDs.append(tracks[index])
                }
            }
            records.append(MTPPlaylistRecord(
                id: playlist.playlist_id,
                name: name,
                trackIDs: trackIDs
            ))
            current = playlist.next
        }
        return records
    }

    private func loadFolderRecords() -> [MTPFolderRecord] {
        guard let head = LIBMTP_Get_Folder_List(device) else {
            _ = drainErrorStack()
            return []
        }
        defer { LIBMTP_destroy_folder_t(head) }

        var records: [MTPFolderRecord] = []
        func walk(_ node: UnsafeMutablePointer<LIBMTP_folder_t>?, parentPath: String) {
            var current = node
            while let pointer = current {
                let folder = pointer.pointee
                let name = string(from: folder.name) ?? "Folder \(folder.folder_id)"
                let path = joinPath(parentPath, name)
                records.append(MTPFolderRecord(
                    id: folder.folder_id,
                    parentID: folder.parent_id,
                    storageID: folder.storage_id,
                    name: name,
                    path: path
                ))
                walk(folder.child, parentPath: path)
                current = folder.sibling
            }
        }

        walk(head, parentPath: "")
        return records
    }

    private func folderIndexCached() throws -> MTPFolderIndex {
        if let cachedFolderIndex {
            return cachedFolderIndex
        }
        let built = try makeFolderIndex()
        cachedFolderIndex = built
        return built
    }

    private func makeFolderIndex() throws -> MTPFolderIndex {
        refreshStorage()
        let storageID = firstStorageID()
        var index = MTPFolderIndex(rootStorageID: storageID)

        for folder in loadFolderRecords() {
            index.insert(MTPFolderLocation(
                id: folder.id,
                storageID: folder.storageID == 0 ? storageID : folder.storageID,
                path: folder.path
            ))
        }

        let defaultMusicFolder = device.pointee.default_music_folder
        if defaultMusicFolder != 0, index.location(path: "Music") == nil {
            let storageID = index.location(id: defaultMusicFolder)?.storageID ?? storageID
            index.insert(MTPFolderLocation(id: defaultMusicFolder, storageID: storageID, path: "Music"))
        }

        return index
    }

    private func ensureFolderPath(_ folderPath: String, in index: inout MTPFolderIndex) throws -> MTPFolderLocation {
        let normalizedPath = normalizedFolderPath(folderPath)
        if let existing = index.location(path: normalizedPath) {
            return existing
        }

        var current = index.root
        var builtPath = ""
        for component in normalizedPath.split(separator: "/").map(String.init) {
            builtPath = joinPath(builtPath, component)
            if let existing = index.location(path: builtPath) {
                current = existing
                continue
            }

            let createdID = try createFolder(named: component, parent: current)
            let created = MTPFolderLocation(id: createdID, storageID: current.storageID, path: builtPath)
            index.insert(created)
            current = created
        }

        return current
    }

    private func createFolder(named name: String, parent: MTPFolderLocation) throws -> UInt32 {
        let parentCandidates: [UInt32]
        if parent.id == Self.rootFolderID {
            parentCandidates = [Self.rootFolderID, 0]
        } else {
            parentCandidates = [parent.id]
        }

        for parentID in parentCandidates {
            var nameBytes = Array(name.utf8CString)
            let createdID = nameBytes.withUnsafeMutableBufferPointer { buffer in
                LIBMTP_Create_Folder(device, buffer.baseAddress, parentID, parent.storageID)
            }
            if createdID != 0 {
                return createdID
            }
        }

        throw operationError(
            code: "folder-create-failed",
            message: "Could not create the Garmin folder \(name).",
            details: drainErrorStack()
        )
    }

    private func downloadSingleFile(
        _ file: DeviceFile,
        objectID: UInt32,
        to target: URL,
        progressBridge: LibMTPProgressBridge?
    ) throws {
        let result = withProgress(progressBridge) { callback, data in
            target.path.withCString { targetPath in
                LIBMTP_Get_File_To_File(device, objectID, targetPath, callback, data)
            }
        }
        let fallbackResult: Int32
        if result != 0, file.type == .audio {
            fallbackResult = withProgress(progressBridge) { callback, data in
                target.path.withCString { targetPath in
                    LIBMTP_Get_Track_To_File(device, objectID, targetPath, callback, data)
                }
            }
        } else {
            fallbackResult = result
        }

        guard fallbackResult == 0,
              fileManager.fileExists(atPath: target.path),
              verifyDownloadedFile(target, expectedSize: file.size) else {
            _ = drainErrorStack()
            try? fileManager.removeItem(at: target)
            try MTPCancelState.throwIfCancelled()
            throw MTPHelperError(
                code: "download-failed",
                message: "Could not download \(file.name) from the Garmin."
            )
        }
    }

    @discardableResult
    private func uploadSingleFile(
        _ uploadFile: DeviceUploadFile,
        localURL: URL,
        folderIndex: inout MTPFolderIndex,
        progressBridge: LibMTPProgressBridge?
    ) throws -> UInt32? {
        let remotePath = normalizedUploadPath(
            uploadFile.remotePath,
            fallbackFileName: localURL.lastPathComponent
        )
        let remoteFileName = (remotePath as NSString).lastPathComponent
        let remoteFolderPath = folderPath(forRemotePath: remotePath)
        let folder = try ensureFolderPath(remoteFolderPath, in: &folderIndex)
        return try sendUpload(
            uploadFile,
            localURL: localURL,
            remoteFileName: remoteFileName,
            folder: folder,
            progressBridge: progressBridge
        )
    }

    @discardableResult
    private func sendUpload(
        _ uploadFile: DeviceUploadFile,
        localURL: URL,
        remoteFileName: String,
        folder: MTPFolderLocation,
        progressBridge: LibMTPProgressBridge?
    ) throws -> UInt32? {
        let fileType = fileType(forFileName: remoteFileName)
        let localSize = UInt64(max(fileSize(at: localURL), 0))

        // Prefer Send_File for Garmin reliability. Track metadata is best-effort
        // and some watches reject Send_Track while accepting the same payload as a file.
        // Trying track-first doubled USB traffic and timeout surface on failure.
        do {
            return try sendFileUpload(
                localURL: localURL,
                remoteFileName: remoteFileName,
                folder: folder,
                fileType: fileType,
                fileSize: localSize,
                progressBridge: progressBridge
            )
        } catch {
            if isAudio(fileType, fileName: remoteFileName),
               let trackID = sendTrackUpload(
                    uploadFile,
                    localURL: localURL,
                    remoteFileName: remoteFileName,
                    folder: folder,
                    fileType: fileType,
                    fileSize: localSize,
                    progressBridge: progressBridge
               ) {
                return trackID
            }
            throw error
        }
    }

    private func sendTrackUpload(
        _ uploadFile: DeviceUploadFile,
        localURL: URL,
        remoteFileName: String,
        folder: MTPFolderLocation,
        fileType: LIBMTP_filetype_t,
        fileSize: UInt64,
        progressBridge: LibMTPProgressBridge?
    ) -> UInt32? {
        guard let track = LIBMTP_new_track_t() else {
            return nil
        }
        defer { LIBMTP_destroy_track_t(track) }

        let metadata = uploadFile.metadata
        track.pointee.parent_id = folder.id
        track.pointee.storage_id = folder.storageID
        track.pointee.filename = duplicatedCString(remoteFileName)
        track.pointee.title = duplicatedCString(metadata?.title ?? (remoteFileName as NSString).deletingPathExtension)
        track.pointee.artist = duplicatedCString(metadata?.artist)
        track.pointee.album = duplicatedCString(metadata?.album)
        track.pointee.duration = metadata?.durationSeconds.flatMap { seconds in
            seconds.isFinite ? UInt32(max(seconds, 0) * 1000) : nil
        } ?? 0
        track.pointee.filesize = fileSize
        track.pointee.filetype = fileType

        let result = withProgress(progressBridge) { callback, data in
            localURL.path.withCString { localPath in
                LIBMTP_Send_Track_From_File(device, localPath, track, callback, data)
            }
        }
        if result == 0 {
            let id = track.pointee.item_id
            return id == 0 ? nil : id
        }

        _ = drainErrorStack()
        return nil
    }

    @discardableResult
    private func sendFileUpload(
        localURL: URL,
        remoteFileName: String,
        folder: MTPFolderLocation,
        fileType: LIBMTP_filetype_t,
        fileSize: UInt64,
        progressBridge: LibMTPProgressBridge?
    ) throws -> UInt32? {
        guard let file = LIBMTP_new_file_t() else {
            throw MTPHelperError(code: "upload-failed", message: "Could not allocate MTP upload metadata.")
        }
        defer { LIBMTP_destroy_file_t(file) }

        file.pointee.parent_id = folder.id
        file.pointee.storage_id = folder.storageID
        file.pointee.filename = duplicatedCString(remoteFileName)
        file.pointee.filesize = fileSize
        file.pointee.filetype = fileType

        let result = withProgress(progressBridge) { callback, data in
            localURL.path.withCString { localPath in
                LIBMTP_Send_File_From_File(device, localPath, file, callback, data)
            }
        }
        guard result == 0 else {
            try MTPCancelState.throwIfCancelled()
            throw operationError(
                code: "upload-failed",
                message: "Could not upload \(remoteFileName) to the Garmin.",
                details: drainErrorStack()
            )
        }
        let id = file.pointee.item_id
        return id == 0 ? nil : id
    }

    /// Holds the bridge alive for the duration of a libmtp call and passes the C trampoline.
    private func withProgress(
        _ bridge: LibMTPProgressBridge?,
        body: (LIBMTP_progressfunc_t?, UnsafeRawPointer?) -> Int32
    ) -> Int32 {
        guard let bridge else {
            return body(nil, nil)
        }
        let unmanaged = Unmanaged.passRetained(bridge)
        defer { unmanaged.release() }
        return body(libmtpProgressTrampoline, unmanaged.toOpaque())
    }

    private func verifyUploadedFiles(_ uploads: [MTPUploadedFile]) -> [String] {
        guard !uploads.isEmpty else { return [] }

        var failures: [String] = []
        var needsFullListing: [MTPUploadedFile] = []

        for upload in uploads {
            if let objectID = upload.objectID, objectID != 0 {
                if verifyObject(objectID: objectID, expectedSize: upload.size) {
                    continue
                }
                // Metadata probe failed — do not fail hard yet; some firmware
                // returns the object ID before size is queryable.
                needsFullListing.append(upload)
            } else {
                needsFullListing.append(upload)
            }
        }

        guard !needsFullListing.isEmpty else { return failures }

        // Only re-list when we lack a trustworthy object ID. This used to run
        // after every successful batch and dominated total transfer time.
        guard let records = try? loadFileRecords() else {
            // If listing fails, keep send-success trust for objects we couldn't
            // verify individually rather than marking the whole batch failed.
            return failures
        }

        let pathsByID = buildPathsByID(from: records)
        var recordsByPath: [String: MTPFileRecord] = [:]
        for record in records {
            let path = pathsByID[record.id] ?? record.name
            recordsByPath[folderKey(path)] = record
        }

        for upload in needsFullListing {
            guard let record = recordsByPath[folderKey(upload.remotePath)] else {
                // Without a path match and without object metadata, trust the
                // libmtp send return code rather than false-negative the upload.
                continue
            }
            let expectedSize = upload.size
            if expectedSize > 0, record.size > 0, clampedInt64(record.size) != expectedSize {
                failures.append(upload.displayName)
            }
        }
        return failures
    }

    private func verifyObject(objectID: UInt32, expectedSize: Int64) -> Bool {
        guard let meta = LIBMTP_Get_Filemetadata(device, objectID) else {
            _ = drainErrorStack()
            return false
        }
        defer { LIBMTP_destroy_file_t(meta) }
        let actual = clampedInt64(meta.pointee.filesize)
        if expectedSize > 0, actual > 0 {
            return actual == expectedSize
        }
        return actual > 0 || expectedSize == 0
    }

    private func buildPathsByID(from records: [MTPFileRecord]) -> [UInt32: String] {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var memo: [UInt32: String] = [
            0: "",
            Self.rootFolderID: ""
        ]

        // Folder list carries full paths; seed the map so file parents resolve to
        // Music/Artist/Album/... instead of basename-only on Garmin devices.
        for folder in loadFolderRecords() {
            if !folder.path.isEmpty {
                memo[folder.id] = folder.path
            } else if !folder.name.isEmpty {
                memo[folder.id] = folder.name
            }
        }

        func resolve(_ id: UInt32, visiting: Set<UInt32> = []) -> String {
            if let cached = memo[id] {
                return cached
            }
            guard let record = byID[id], !visiting.contains(id) else {
                memo[id] = ""
                return ""
            }
            var nextVisiting = visiting
            nextVisiting.insert(id)
            let parentPath = resolve(record.parentID, visiting: nextVisiting)
            let path = joinPath(parentPath, record.name)
            memo[id] = path
            return path
        }

        for record in records {
            _ = resolve(record.id)
        }
        return memo
    }

    private func deviceFile(
        from record: MTPFileRecord,
        path: String,
        metadata: DeviceAudioMetadata?,
        typeOverride: DeviceFileType? = nil
    ) -> DeviceFile {
        DeviceFile(
            objectID: String(record.id),
            name: record.name,
            type: typeOverride ?? deviceFileType(for: record.fileType, fileName: record.name),
            size: clampedInt64(record.size),
            parentID: String(record.parentID),
            path: path,
            backendKind: .mtp,
            modifiedDate: record.modifiedDate,
            audioMetadata: metadata
        )
    }

    private func deviceFile(from track: MTPTrackRecord, pathsByID: [UInt32: String]) -> DeviceFile {
        let parentPath = pathsByID[track.parentID] ?? "Music"
        let path = joinPath(parentPath.isEmpty ? "Music" : parentPath, track.fileName)
        return DeviceFile(
            objectID: String(track.id),
            name: track.fileName,
            type: .audio,
            size: clampedInt64(track.size),
            parentID: String(track.parentID),
            path: path,
            backendKind: .mtp,
            modifiedDate: track.modifiedDate,
            audioMetadata: track.metadata
        )
    }

    private func placeholderPlaylistFile(trackID: UInt32, playlists: [MTPPlaylistRecord]) -> DeviceFile {
        let playlistName = playlists.first { $0.trackIDs.contains(trackID) }?.name ?? "Playlist"
        let displayName = "Track ID \(trackID)"
        return DeviceFile(
            objectID: String(trackID),
            name: displayName,
            type: .audio,
            size: 0,
            parentID: nil,
            path: joinPath("Music", joinPath(playlistName, displayName)),
            backendKind: .mtp,
            audioMetadata: DeviceAudioMetadata(title: displayName)
        )
    }

    private func musicCollections(
        for files: [DeviceFile],
        playlists: [MTPPlaylistRecord],
        m3uPlaylists: [DeviceCollection] = [],
        knownFileIDs: Set<String>
    ) -> [DeviceCollection] {
        var collections = [
            DeviceCollection(id: "all-music", name: "All Music", kind: .allMusic, fileIDs: files.map(\.id))
        ]

        var playlistNames = Set<String>()

        for playlist in playlists {
            let fileIDs = playlist.trackIDs.map { "mtp:\($0)" }
            let matched = fileIDs.filter { knownFileIDs.contains($0) }
            let unmatched = zip(fileIDs, playlist.trackIDs)
                .filter { !knownFileIDs.contains($0.0) }
                .map { "Track ID \($0.1)" }
            guard !matched.isEmpty || !unmatched.isEmpty else { continue }
            collections.append(DeviceCollection(
                id: "playlist:\(playlist.id)",
                name: playlist.name,
                kind: .playlist,
                fileIDs: matched,
                unmatchedItems: unmatched
            ))
            playlistNames.insert(playlist.name.lowercased())
        }

        // File-based playlists (.m3u8) — primary source on many Garmin watches.
        for collection in m3uPlaylists {
            let key = collection.name.lowercased()
            if playlistNames.contains(key) { continue }
            collections.append(collection)
            playlistNames.insert(key)
        }

        let grouped = Dictionary(grouping: files) { file in
            let parent = (file.path as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }
        for (folder, folderFiles) in grouped.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            guard !folder.isEmpty else { continue }
            // Prefer top-level Music/Playlist-style folders; skip ultra-deep noise if huge.
            collections.append(DeviceCollection(
                id: "folder:\(folder)",
                name: (folder as NSString).lastPathComponent,
                kind: .folder,
                fileIDs: folderFiles.map(\.id)
            ))
        }

        // All Music, then playlists (A–Z), then albums/folders (A–Z).
        return collections.sorted { lhs, rhs in
            let lhsRank = collectionSortRank(lhs.kind)
            let rhsRank = collectionSortRank(rhs.kind)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func collectionSortRank(_ kind: DeviceCollectionKind) -> Int {
        switch kind {
        case .allMusic: return 0
        case .playlist: return 1
        case .album: return 2
        case .folder: return 3
        }
    }

    /// Download on-device `.m3u` / `.m3u8` files and build playlist collections.
    private func loadM3UPlaylistCollections(
        from fileRecords: [MTPFileRecord],
        audioFiles: [DeviceFile]
    ) -> [DeviceCollection] {
        let playlistFiles = fileRecords.filter { isPlaylist($0.name) }
        guard !playlistFiles.isEmpty else { return [] }

        var collections: [DeviceCollection] = []
        for record in playlistFiles.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            if MTPCancelState.isCancelled { break }
            guard let text = readObjectText(objectID: record.id, preferredFileName: record.name) else {
                continue
            }
            let references = M3UPlaylistParser.parseTrackPaths(from: text)
            guard !references.isEmpty else { continue }
            let match = M3UPlaylistParser.match(references: references, files: audioFiles)
            guard !match.fileIDs.isEmpty || !match.unmatchedItems.isEmpty else { continue }
            let displayName = M3UPlaylistParser.playlistDisplayName(fromFileName: record.name)
            collections.append(DeviceCollection(
                id: "m3u:\(record.id)",
                name: displayName,
                kind: .playlist,
                fileIDs: match.fileIDs,
                unmatchedItems: match.unmatchedItems
            ))
        }
        return collections
    }

    /// Fetch a small text object (playlist) from the device into a temp file and return UTF-8 contents.
    private func readObjectText(objectID: UInt32, preferredFileName: String) -> String? {
        let safeName = sanitizedFileName(preferredFileName, fallback: "playlist.m3u8")
        let target = fileManager.temporaryDirectory
            .appendingPathComponent("gmm-playlist-\(objectID)-\(UUID().uuidString)-\(safeName)")
        defer { try? fileManager.removeItem(at: target) }

        let result = target.path.withCString { targetPath in
            LIBMTP_Get_File_To_File(device, objectID, targetPath, nil, nil)
        }
        guard result == 0, fileManager.fileExists(atPath: target.path) else {
            _ = drainErrorStack()
            return nil
        }

        if let utf8 = try? String(contentsOf: target, encoding: .utf8) {
            return utf8
        }
        // Some tools write Latin-1 / Windows playlists.
        if let data = try? Data(contentsOf: target),
           let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return nil
    }

    private func storageInfo(files: [DeviceFile]) -> DeviceStorageInfo {
        var total: UInt64 = 0
        var free: UInt64 = 0
        var storage = device.pointee.storage
        while let pointer = storage {
            let value = pointer.pointee
            total += value.MaxCapacity
            free += value.FreeSpaceInBytes
            storage = value.next
        }

        return DeviceStorageInfo(
            totalCapacity: total == 0 ? nil : clampedInt64(total),
            availableCapacity: free == 0 ? nil : clampedInt64(free),
            usedByFiles: files.reduce(Int64(0)) { $0 + max($1.size, 0) },
            fileCount: files.count
        )
    }

    @discardableResult
    private func refreshStorage() -> Int32 {
        let result = LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED)
        lastStorageResult = result
        return result
    }

    /// Some Garmin firmware answers LIBMTP_Get_Storage with an error or zero
    /// capacities; surface that instead of silently hiding the storage gauge.
    private func storageDiagnostic(_ info: DeviceStorageInfo) -> String? {
        guard info.totalCapacity == nil else { return nil }
        if let lastStorageResult, lastStorageResult != 0 {
            return "Storage capacity unavailable (libmtp Get_Storage returned \(lastStorageResult))."
        }
        return "Storage capacity unavailable (the Garmin did not report its capacity)."
    }

    private func firstStorageID() -> UInt32 {
        if device.pointee.storage == nil {
            refreshStorage()
        }
        return device.pointee.storage?.pointee.id ?? 0
    }

    private func deviceDisplayName() -> String {
        if let friendlyName = copyStringAndFree(LIBMTP_Get_Friendlyname(device)), !friendlyName.isEmpty {
            return friendlyName
        }
        let manufacturer = copyStringAndFree(LIBMTP_Get_Manufacturername(device))
        let model = copyStringAndFree(LIBMTP_Get_Modelname(device))
        let name = [manufacturer, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? rawDevice.displayName : name
    }

    private func drainErrorStack() -> [String] {
        guard let stack = LIBMTP_Get_Errorstack(device) else { return [] }
        var messages: [String] = []
        var current: UnsafeMutablePointer<LIBMTP_error_t>? = stack
        while let pointer = current {
            if let message = string(from: pointer.pointee.error_text), !message.isEmpty {
                messages.append(message)
            }
            current = pointer.pointee.next
        }
        LIBMTP_Clear_Errorstack(device)
        return messages
    }

    private func operationError(code: String, message: String, details: [String]) -> MTPHelperError {
        let cleanedDetails = details
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let translated = MTPErrorTranslator.friendlyMessage(for: cleanedDetails)
        let detail = cleanedDetails.joined(separator: " ")
        return MTPHelperError(
            code: code,
            message: translated.map { "\(message) \($0)" } ?? message,
            recoverySuggestion: "Close Garmin Express, OpenMTP, Android File Transfer, or any other app using the watch, then reconnect the Garmin and refresh.",
            diagnosticDetail: detail.isEmpty ? nil : detail
        )
    }

    private static func error(forDetectionResult result: LIBMTP_error_number_t) -> MTPHelperError {
        switch result {
        case LIBMTP_ERROR_NO_DEVICE_ATTACHED:
            return noDeviceError()
        case LIBMTP_ERROR_CONNECTING, LIBMTP_ERROR_USB_LAYER, LIBMTP_ERROR_PTP_LAYER:
            return busyError(rawDevice: nil, details: ["libmtp reported \(result)."])
        case LIBMTP_ERROR_MEMORY_ALLOCATION:
            return MTPHelperError(code: "memory", message: "MTP could not allocate enough memory to scan devices.")
        default:
            return MTPHelperError(
                code: "mtp-detect-failed",
                message: "MTP device detection failed.",
                recoverySuggestion: "Reconnect the Garmin with a data USB cable, wake it, then refresh."
            )
        }
    }

    private static func noDeviceError() -> MTPHelperError {
        MTPHelperError(
            code: "no-device",
            message: "No Garmin MTP device is responding.",
            recoverySuggestion: "Connect the watch with a data USB cable, wake it, close Garmin Express or other transfer apps, then refresh."
        )
    }

    private static func busyError(rawDevice: RawDeviceDescriptor?, details: [String]) -> MTPHelperError {
        let target = rawDevice?.displayName ?? "Garmin"
        let detailText = details.filter { !$0.isEmpty }.joined(separator: " ")
        let message = detailText.isEmpty
            ? "\(target) is visible, but MTP could not open the USB connection."
            : "\(target) is visible, but MTP could not open the USB connection. \(detailText)"
        return MTPHelperError(
            code: "device-busy",
            message: message,
            recoverySuggestion: "Close Garmin Express, OpenMTP, Android File Transfer, Photos, or any other app using the watch. Then unplug the Garmin, plug it back in, wait a few seconds, and refresh."
        )
    }

    private func normalizedUploadPath(_ path: String, fallbackFileName: String) -> String {
        let cleaned = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        let rawComponents = cleaned.split(separator: "/").map(String.init)
        let components = rawComponents
            .map { sanitizedPathComponent($0, fallback: "Folder") }
            .filter { !$0.isEmpty }

        if components.isEmpty {
            return joinPath("Music", sanitizedFileName(fallbackFileName, fallback: "Track"))
        }
        if components.count == 1 {
            return joinPath("Music", sanitizedFileName(components[0], fallback: "Track"))
        }

        let folderComponents = components.dropLast().map { sanitizedPathComponent($0, fallback: "Folder") }
        let fileName = sanitizedFileName(components.last ?? fallbackFileName, fallback: "Track")
        return (folderComponents + [fileName]).joined(separator: "/")
    }

    private func folderPath(forRemotePath path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty || folder == "." ? "Music" : folder
    }

    private func normalizedFolderPath(_ path: String) -> String {
        let cleaned = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        let components = cleaned.split(separator: "/")
            .map { sanitizedPathComponent(String($0), fallback: "Folder") }
            .filter { !$0.isEmpty }
        return components.isEmpty ? "Music" : components.joined(separator: "/")
    }

    private func sanitizedPathComponent(_ value: String, fallback: String) -> String {
        sanitizedFileName(value, fallback: fallback)
    }

    private func sanitizedFileName(_ name: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func uniqueURL(in folderURL: URL, preferredFileName: String) -> URL {
        let preferredURL = folderURL.appendingPathComponent(preferredFileName)
        if !fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidateURL = folderURL.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return folderURL.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }

    private func verifyDownloadedFile(_ url: URL, expectedSize: Int64) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let actualSize = fileSize(at: url)
        if expectedSize > 0 {
            return actualSize == expectedSize
        }
        return actualSize > 0
    }

    private func fileSize(at url: URL) -> Int64 {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
    }

    private func resultMessage(action: String, count: Int, failures: Int) -> String {
        if failures == 0 {
            return "\(count) file(s) \(action)."
        }
        return "\(count) file(s) \(action); \(failures) failed."
    }

    private func date(from value: time_t) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    private func clampedInt64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private func deviceFileType(for fileType: LIBMTP_filetype_t, fileName: String) -> DeviceFileType {
        if fileType == LIBMTP_FILETYPE_FOLDER { return .folder }
        if fileType == LIBMTP_FILETYPE_PLAYLIST || isPlaylist(fileName) { return .playlist }
        if isAudio(fileType, fileName: fileName) { return .audio }
        return .other
    }

    private func shouldExposeAsMusic(
        _ record: MTPFileRecord,
        path: String,
        playlistTrackIDs: Set<UInt32>
    ) -> Bool {
        guard record.fileType != LIBMTP_FILETYPE_FOLDER,
              record.fileType != LIBMTP_FILETYPE_PLAYLIST,
              !isPlaylist(record.name) else {
            return false
        }

        if isAudio(record.fileType, fileName: record.name) {
            return true
        }
        if playlistTrackIDs.contains(record.id) {
            return true
        }
        return isGenericMusicObject(record, path: path)
    }

    private func isGenericMusicObject(_ record: MTPFileRecord, path: String) -> Bool {
        guard record.size > 0,
              record.fileType == LIBMTP_FILETYPE_UNKNOWN || record.fileType == LIBMTP_FILETYPE_MP4 else {
            return false
        }

        let ext = (record.name as NSString).pathExtension.lowercased()
        guard !Self.nonAudioMusicAreaExtensions.contains(ext) else { return false }
        return isLikelyMusicPath(path)
    }

    private func isAudio(_ fileType: LIBMTP_filetype_t, fileName: String) -> Bool {
        if fileType == LIBMTP_FILETYPE_WAV
            || fileType == LIBMTP_FILETYPE_MP3
            || fileType == LIBMTP_FILETYPE_MP2
            || fileType == LIBMTP_FILETYPE_WMA
            || fileType == LIBMTP_FILETYPE_OGG
            || fileType == LIBMTP_FILETYPE_FLAC
            || fileType == LIBMTP_FILETYPE_AAC
            || fileType == LIBMTP_FILETYPE_M4A
            || fileType == LIBMTP_FILETYPE_AUDIBLE
            || fileType == LIBMTP_FILETYPE_UNDEF_AUDIO {
            return true
        }
        return Self.supportedAudioExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    private func isPlaylist(_ fileName: String) -> Bool {
        Self.supportedPlaylistExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    private func isLikelyMusicPath(_ path: String) -> Bool {
        let components = folderKey(path)
            .split(separator: "/")
            .map { String($0).lowercased() }
        return components.contains("music")
            || components.contains("podcast")
            || components.contains("podcasts")
            || components.contains("audiobook")
            || components.contains("audiobooks")
            || components.contains("audible")
            || components.contains("spotify")
            || components.contains("deezer")
            || components.contains("amazonmusic")
            || components.contains("media")
    }

    private func musicDiagnostic(
        files: [DeviceFile],
        rawFileCount: Int,
        trackCount: Int,
        playlistCount: Int,
        playlistTrackCount: Int
    ) -> String? {
        guard files.isEmpty else {
            let promotedCount = files.filter { file in
                guard let objectID = file.objectID.flatMap(UInt32.init) else { return false }
                return playlistTrackCount > 0 && file.name == "Track ID \(objectID)"
            }.count
            guard promotedCount > 0 else { return nil }
            return "Some Garmin playlist items did not expose filenames, so they are shown by track ID."
        }

        if trackCount > 0 || playlistTrackCount > 0 || playlistCount > 0 {
            return "Garmin exposed \(trackCount) track record(s), \(playlistCount) playlist(s), and \(playlistTrackCount) playlist item(s), but no downloadable audio filenames. Streaming-provider music may be protected."
        }
        if rawFileCount > 0 {
            return "Garmin exposed \(rawFileCount) storage object(s), but none were labeled as compatible audio. Streaming-provider music may be protected or hidden from MTP file access."
        }
        return "Garmin responded, but did not expose any music files or playlists over MTP."
    }

    private func fileType(forFileName fileName: String) -> LIBMTP_filetype_t {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp3":
            return LIBMTP_FILETYPE_MP3
        case "m4a", "alac":
            return LIBMTP_FILETYPE_M4A
        case "aac":
            return LIBMTP_FILETYPE_AAC
        case "wav":
            return LIBMTP_FILETYPE_WAV
        case "flac":
            return LIBMTP_FILETYPE_FLAC
        case "m3u", "m3u8", "pls":
            return LIBMTP_FILETYPE_PLAYLIST
        default:
            return LIBMTP_FILETYPE_UNKNOWN
        }
    }

    private static let nonAudioMusicAreaExtensions: Set<String> = [
        "bmp", "db", "fit", "gcd", "gif", "ini", "jpeg", "jpg", "json", "log", "png", "tmp", "txt", "xml"
    ]
}
