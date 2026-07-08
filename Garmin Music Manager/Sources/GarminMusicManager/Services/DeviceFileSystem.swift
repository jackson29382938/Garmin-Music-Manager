import Foundation
import GarminMusicCore

typealias MTPTransferProgressHandler = @Sendable (MTPProgressEvent) -> Void

protocol DeviceFileSystem {
    var deviceID: String { get }
    var displayName: String { get }
    var backendKind: DeviceBackendKind { get }
    var supportsMove: Bool { get }

    func listMusic() async throws -> DeviceFileSystemSnapshot
    func listStorageTree() async throws -> DeviceFileSystemSnapshot
    func download(
        _ files: [DeviceFile],
        to destinationFolder: URL,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult
    func upload(
        _ files: [DeviceUploadFile],
        syncSettings: SyncSettings?,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult
    func delete(_ files: [DeviceFile]) async throws -> DeviceFileOperationResult
    func move(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult
    func storageInfo() async throws -> DeviceStorageInfo?
    /// Optional: create a native device playlist. Default is unsupported.
    func createPlaylist(name: String, tracks: [DeviceFile]) async throws -> DeviceFileOperationResult
}

extension DeviceFileSystem {
    func createPlaylist(name: String, tracks: [DeviceFile]) async throws -> DeviceFileOperationResult {
        throw DeviceFileSystemError.unsupported("Playlists are only created over MTP.")
    }
}

enum DeviceFileSystemError: LocalizedError {
    case helperMissing
    case helperFailed(String)
    case unsupported(String)
    case missingDestination
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The bundled Garmin helper is missing. Rebuild the app bundle and try again."
        case .helperFailed(let message):
            return message
        case .unsupported(let message):
            return message
        case .missingDestination:
            return "Choose a destination folder first."
        case .verificationFailed(let message):
            return message
        }
    }
}

final class MountedFolderDeviceFileSystem: DeviceFileSystem {
    let deviceID: String
    let displayName: String
    let backendKind: DeviceBackendKind = .mountedFolder
    let supportsMove = true

    private let rootURL: URL
    private let fileManager: FileManager
    private let audioExtensions = MusicScanner.supportedAudioExtensions
    private let playlistExtensions = MusicScanner.supportedPlaylistExtensions

    init(rootURL: URL, displayName: String? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.displayName = displayName ?? rootURL.lastPathComponent
        self.deviceID = "mounted:\(rootURL.path)"
        self.fileManager = fileManager
    }

    func listMusic() async throws -> DeviceFileSystemSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let files = try self.listFiles(includeAllFiles: false)
            return DeviceFileSystemSnapshot(
                files: files,
                collections: self.collections(for: files, includeFolders: true),
                storageInfo: self.storageInfoSync(for: files),
                deviceName: self.displayName,
                diagnosticMessage: files.isEmpty ? "No compatible audio files were found in this folder." : nil
            )
        }.value
    }

    func listStorageTree() async throws -> DeviceFileSystemSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let files = try self.listFiles(includeAllFiles: true)
            return DeviceFileSystemSnapshot(
                files: files,
                collections: [
                    DeviceCollection(id: "all-storage", name: "All Storage", kind: .folder, fileIDs: files.map(\.id))
                ],
                storageInfo: self.storageInfoSync(for: files),
                deviceName: self.displayName,
                diagnosticMessage: nil
            )
        }.value
    }

    func download(
        _ files: [DeviceFile],
        to destinationFolder: URL,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult {
        try await Task.detached(priority: .userInitiated) {
            try self.fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            var copied = 0
            var failures: [String] = []
            let itemCount = files.count
            let totalBytes = files.reduce(Int64(0)) { $0 + max($1.size, 0) }
            var completedBytes: Int64 = 0

            for (index, file) in files.enumerated() {
                let itemBytes = max(file.size, 0)
                onProgress?(
                    MTPProgressEvent(
                        phase: "download",
                        itemIndex: index,
                        itemCount: itemCount,
                        itemName: file.name,
                        bytesTransferred: 0,
                        bytesTotal: itemBytes > 0 ? itemBytes : nil,
                        overallFraction: totalBytes > 0
                            ? Double(completedBytes) / Double(totalBytes)
                            : Double(index) / Double(max(itemCount, 1)),
                        message: "Copying \(index + 1)/\(itemCount): \(file.name)"
                    )
                )
                do {
                    let source = self.url(for: file)
                    let target = FileNameSanitizer.uniqueURL(
                        in: destinationFolder,
                        preferredFileName: FileNameSanitizer.sanitizeFileName(file.name, fallback: "Garmin File")
                    )
                    try self.fileManager.copyItem(at: source, to: target)
                    try self.verifyCopy(source: source, target: target)
                    copied += 1
                    completedBytes += itemBytes
                    onProgress?(
                        MTPProgressEvent(
                            phase: "download",
                            itemIndex: index,
                            itemCount: itemCount,
                            itemName: file.name,
                            bytesTransferred: itemBytes,
                            bytesTotal: itemBytes > 0 ? itemBytes : nil,
                            overallFraction: totalBytes > 0
                                ? Double(completedBytes) / Double(totalBytes)
                                : Double(index + 1) / Double(max(itemCount, 1)),
                            message: "Copied \(index + 1)/\(itemCount): \(file.name)"
                        )
                    )
                } catch {
                    failures.append(file.name)
                }
            }

            return DeviceFileOperationResult(
                completedCount: copied,
                failedItems: failures,
                message: self.resultMessage(action: "copied", count: copied, failures: failures.count)
            )
        }.value
    }

    func upload(
        _ files: [DeviceUploadFile],
        syncSettings: SyncSettings?,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult {
        await Task.detached(priority: .userInitiated) {
            var copied = 0
            var skipped = 0
            var failures: [String] = []
            let itemCount = files.count
            let totalBytes = files.reduce(Int64(0)) { partial, file in
                partial + max(self.fileSize(at: URL(fileURLWithPath: file.localPath)), 0)
            }
            var completedBytes: Int64 = 0

            for (index, file) in files.enumerated() {
                do {
                    let source = URL(fileURLWithPath: file.localPath)
                    let relativePath = file.remotePath.isEmpty ? source.lastPathComponent : file.remotePath
                    let target = self.rootURL.appendingPathComponent(relativePath)
                    try self.fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

                    let sourceSize = self.fileSize(at: source)
                    onProgress?(
                        MTPProgressEvent(
                            phase: "upload",
                            itemIndex: index,
                            itemCount: itemCount,
                            itemName: file.displayName,
                            bytesTransferred: 0,
                            bytesTotal: sourceSize > 0 ? sourceSize : nil,
                            overallFraction: totalBytes > 0
                                ? Double(completedBytes) / Double(totalBytes)
                                : Double(index) / Double(max(itemCount, 1)),
                            message: "Copying \(index + 1)/\(itemCount): \(file.displayName)"
                        )
                    )

                    let finalTarget: URL
                    if self.fileManager.fileExists(atPath: target.path), let settings = syncSettings {
                        switch self.resolveUploadAction(sourceSize: sourceSize, target: target, settings: settings) {
                        case .skip:
                            skipped += 1
                            completedBytes += sourceSize
                            continue
                        case .replace:
                            try self.fileManager.removeItem(at: target)
                            finalTarget = target
                        case .keepBoth:
                            finalTarget = FileNameSanitizer.uniqueURL(
                                in: target.deletingLastPathComponent(),
                                preferredFileName: target.lastPathComponent
                            )
                        }
                    } else {
                        finalTarget = self.fileManager.fileExists(atPath: target.path)
                            ? FileNameSanitizer.uniqueURL(in: target.deletingLastPathComponent(), preferredFileName: target.lastPathComponent)
                            : target
                    }

                    try self.fileManager.copyItem(at: source, to: finalTarget)
                    try self.verifyCopy(source: source, target: finalTarget)
                    copied += 1
                    completedBytes += sourceSize
                    onProgress?(
                        MTPProgressEvent(
                            phase: "upload",
                            itemIndex: index,
                            itemCount: itemCount,
                            itemName: file.displayName,
                            bytesTransferred: sourceSize,
                            bytesTotal: sourceSize > 0 ? sourceSize : nil,
                            overallFraction: totalBytes > 0
                                ? Double(completedBytes) / Double(totalBytes)
                                : Double(index + 1) / Double(max(itemCount, 1)),
                            message: "Copied \(index + 1)/\(itemCount): \(file.displayName)"
                        )
                    )
                } catch {
                    failures.append(file.displayName)
                }
            }

            let total = copied + skipped
            var message = self.resultMessage(action: "uploaded", count: copied, failures: failures.count)
            if skipped > 0 {
                message += " Skipped \(skipped) identical file(s)."
            }
            return DeviceFileOperationResult(
                completedCount: total,
                failedItems: failures,
                message: message
            )
        }.value
    }

    private enum MountedUploadAction {
        case skip
        case replace
        case keepBoth
    }

    private func resolveUploadAction(sourceSize: Int64, target: URL, settings: SyncSettings) -> MountedUploadAction {
        guard fileManager.fileExists(atPath: target.path) else { return .replace }

        switch settings.overwritePolicy {
        case .skipIdentical:
            let targetSize = fileSize(at: target)
            if sourceSize > 0, targetSize > 0, sourceSize == targetSize {
                return .skip
            }
            return .replace
        case .replace:
            return .replace
        case .keepBoth:
            return .keepBoth
        }
    }

    func delete(_ files: [DeviceFile]) async throws -> DeviceFileOperationResult {
        await Task.detached(priority: .userInitiated) {
            var deleted = 0
            var failures: [String] = []

            for file in files {
                do {
                    let source = self.url(for: file)
                    if self.fileManager.fileExists(atPath: source.path) {
                        try self.fileManager.removeItem(at: source)
                        deleted += 1
                    }
                } catch {
                    failures.append(file.name)
                }
            }

            return DeviceFileOperationResult(
                completedCount: deleted,
                failedItems: failures,
                message: self.resultMessage(action: "deleted", count: deleted, failures: failures.count)
            )
        }.value
    }

    func move(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult {
        try await Task.detached(priority: .userInitiated) {
            try self.fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            var moved = 0
            var failures: [String] = []

            for file in files {
                do {
                    let source = self.url(for: file)
                    let target = FileNameSanitizer.uniqueURL(
                        in: destinationFolder,
                        preferredFileName: FileNameSanitizer.sanitizeFileName(file.name, fallback: "Garmin File")
                    )
                    let expectedSize = self.fileSize(at: source)
                    try self.fileManager.moveItem(at: source, to: target)
                    guard self.fileManager.fileExists(atPath: target.path), self.fileSize(at: target) == expectedSize else {
                        throw DeviceFileSystemError.verificationFailed("Move verification failed for \(file.name).")
                    }
                    moved += 1
                } catch {
                    failures.append(file.name)
                }
            }

            return DeviceFileOperationResult(
                completedCount: moved,
                failedItems: failures,
                message: self.resultMessage(action: "moved", count: moved, failures: failures.count)
            )
        }.value
    }

    func storageInfo() async throws -> DeviceStorageInfo? {
        try await Task.detached(priority: .userInitiated) {
            self.storageInfoSync(for: try self.listFiles(includeAllFiles: false))
        }.value
    }

    func createPlaylist(name: String, tracks: [DeviceFile]) async throws -> DeviceFileOperationResult {
        throw DeviceFileSystemError.unsupported(
            "Mounted folders use .m3u8 playlist files instead of native MTP playlists."
        )
    }

    private func listFiles(includeAllFiles: Bool) throws -> [DeviceFile] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [DeviceFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]) else {
                continue
            }
            let type = fileType(for: url, isDirectory: values.isDirectory == true)
            if !includeAllFiles, type != .audio {
                continue
            }

            files.append(DeviceFile(
                objectID: nil,
                name: url.lastPathComponent,
                type: type,
                size: Int64(values.fileSize ?? 0),
                parentID: nil,
                path: relativePath(for: url),
                backendKind: .mountedFolder,
                modifiedDate: values.contentModificationDate,
                audioMetadata: nil
            ))
        }

        return files.sorted {
            if $0.type == .folder, $1.type != .folder { return true }
            if $0.type != .folder, $1.type == .folder { return false }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func collections(for files: [DeviceFile], includeFolders: Bool) -> [DeviceCollection] {
        var collections = [
            DeviceCollection(id: "all-music", name: "All Music", kind: .allMusic, fileIDs: files.map(\.id))
        ]

        guard includeFolders else { return collections }

        let grouped = Dictionary(grouping: files) { file in
            let parent = (file.path as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }

        for (folder, folderFiles) in grouped.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            guard !folder.isEmpty else { continue }
            collections.append(DeviceCollection(
                id: "folder:\(folder)",
                name: (folder as NSString).lastPathComponent,
                kind: .folder,
                fileIDs: folderFiles.map(\.id)
            ))
        }

        return collections
    }

    private func storageInfoSync(for files: [DeviceFile]) -> DeviceStorageInfo {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        let values = try? rootURL.resourceValues(forKeys: keys)
        return DeviceStorageInfo(
            totalCapacity: values?.volumeTotalCapacity.map { Int64($0) },
            availableCapacity: values?.volumeAvailableCapacityForImportantUsage.map { Int64($0) },
            usedByFiles: files.reduce(Int64(0)) { $0 + max($1.size, 0) },
            fileCount: files.count
        )
    }

    private func fileType(for url: URL, isDirectory: Bool) -> DeviceFileType {
        if isDirectory { return .folder }
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if playlistExtensions.contains(ext) { return .playlist }
        return .other
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    private func url(for file: DeviceFile) -> URL {
        rootURL.appendingPathComponent(file.path)
    }

    private func verifyCopy(source: URL, target: URL) throws {
        guard fileManager.fileExists(atPath: target.path) else {
            throw DeviceFileSystemError.verificationFailed("Copy finished but no destination file was created.")
        }
        guard fileSize(at: source) == fileSize(at: target) else {
            throw DeviceFileSystemError.verificationFailed("Copy verification failed because file sizes did not match.")
        }
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
}

final class MTPDeviceFileSystem: DeviceFileSystem {
    let deviceID: String
    let displayName: String
    let backendKind: DeviceBackendKind = .mtp
    let supportsMove = false

    private let helperClient: MTPHelperClient

    init(deviceID: String, displayName: String, helperClient: MTPHelperClient = MTPHelperClient()) {
        self.deviceID = "mtp:\(deviceID)"
        self.displayName = displayName
        self.helperClient = helperClient
    }

    func listMusic() async throws -> DeviceFileSystemSnapshot {
        try await helperClient.snapshot(request: MTPHelperRequest(operation: .listMusic, browseMode: .musicOnly))
    }

    func listStorageTree() async throws -> DeviceFileSystemSnapshot {
        try await helperClient.snapshot(request: MTPHelperRequest(operation: .listStorageTree, browseMode: .advancedStorage))
    }

    func download(
        _ files: [DeviceFile],
        to destinationFolder: URL,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult {
        try await helperClient.operationResult(
            request: MTPHelperRequest(
                operation: .download,
                files: files,
                destinationPath: destinationFolder.path
            ),
            onProgress: onProgress
        )
    }

    func upload(
        _ files: [DeviceUploadFile],
        syncSettings: SyncSettings?,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult {
        _ = syncSettings
        return try await helperClient.operationResult(
            request: MTPHelperRequest(operation: .upload, uploadFiles: files),
            onProgress: onProgress
        )
    }

    func delete(_ files: [DeviceFile]) async throws -> DeviceFileOperationResult {
        try await helperClient.operationResult(request: MTPHelperRequest(operation: .delete, files: files))
    }

    func move(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult {
        throw DeviceFileSystemError.unsupported("Move is disabled for this Garmin MTP connection. Copy to Mac, delete, or re-sync to a different playlist/folder instead.")
    }

    func storageInfo() async throws -> DeviceStorageInfo? {
        try await listMusic().storageInfo
    }

    func createPlaylist(name: String, tracks: [DeviceFile]) async throws -> DeviceFileOperationResult {
        try await helperClient.operationResult(
            request: MTPHelperRequest(
                operation: .createPlaylist,
                files: tracks,
                playlistName: name
            )
        )
    }
}

final class MTPHelperClient {
    /// Preferred batch size for MTP uploads. Smaller batches improve progress
    /// reporting and limit how much work is lost when a single transfer glitches.
    static let uploadChunkSize = 5

    private let transport: MTPHelperTransport?

    /// Shared long-lived helper so every MTPDeviceFileSystem instance reuses one session.
    private static var sharedPersistent: (url: URL, transport: PersistentMTPHelperTransport)?

    init(helperURL: URL? = nil, preferPersistent: Bool = true) {
        let url = helperURL ?? Self.locateHelper()
        if let url {
            if preferPersistent {
                self.transport = Self.sharedPersistentTransport(for: url)
            } else {
                self.transport = SubprocessMTPHelperTransport(helperURL: url)
            }
        } else {
            self.transport = nil
        }
    }

    init(transport: MTPHelperTransport) {
        self.transport = transport
    }

    static func shutdownSharedHelper() async {
        let transport: PersistentMTPHelperTransport? = Self.transportQueue.sync {
            let existing = sharedPersistent?.transport
            sharedPersistent = nil
            return existing
        }
        await transport?.shutdown()
    }

    /// Abort the current MTP transfer (cooperative SIGUSR1, then hard kill).
    /// Prefer this on user Cancel so mid-file USB work stops promptly.
    static func cancelInFlightHelper() async {
        let transport = transportQueue.sync { sharedPersistent?.transport }
        await transport?.interrupt()
    }

    private static let transportQueue = DispatchQueue(label: "com.garminmusicmanager.mtp-helper-transport")

    private static func sharedPersistentTransport(for url: URL) -> PersistentMTPHelperTransport {
        transportQueue.sync {
            if let existing = sharedPersistent, existing.url.path == url.path {
                return existing.transport
            }
            let created = PersistentMTPHelperTransport(helperURL: url)
            sharedPersistent = (url, created)
            return created
        }
    }

    func snapshot(request: MTPHelperRequest) async throws -> DeviceFileSystemSnapshot {
        let response = try await perform(request: request, timeout: request.operation == .listStorageTree ? 180 : 90)
        guard let snapshot = response.snapshot else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper did not return device files.")
        }
        return snapshot
    }

    func operationResult(
        request: MTPHelperRequest,
        onProgress: MTPTransferProgressHandler? = nil
    ) async throws -> DeviceFileOperationResult {
        // Chunk large uploads so one flaky file doesn't burn a multi-hour timeout
        // and so the UI can advance between chunks (caller may also chunk).
        if request.operation == .upload, request.uploadFiles.count > Self.uploadChunkSize {
            return try await uploadInChunks(request.uploadFiles, onProgress: onProgress)
        }

        let response = try await perform(
            request: request,
            timeout: operationTimeout(for: request),
            onProgress: onProgress
        )
        guard let result = response.operationResult else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper did not return an operation result.")
        }
        if !response.ok, result.completedCount == 0 {
            throw DeviceFileSystemError.helperFailed(result.message ?? "The Garmin operation failed.")
        }
        return result
    }

    private func uploadInChunks(
        _ files: [DeviceUploadFile],
        onProgress: MTPTransferProgressHandler?
    ) async throws -> DeviceFileOperationResult {
        var completed = 0
        var failures: [String] = []
        let chunks = stride(from: 0, to: files.count, by: Self.uploadChunkSize).map {
            Array(files[$0..<min($0 + Self.uploadChunkSize, files.count)])
        }
        let totalBytes = files.reduce(Int64(0)) { $0 + max(Self.fileSize(atPath: $1.localPath), 0) }
        /// Only bytes from successful (or proportionally successful) chunks.
        var completedBytes: Int64 = 0

        for (chunkIndex, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let chunkBytes = chunk.reduce(Int64(0)) { $0 + max(Self.fileSize(atPath: $1.localPath), 0) }
            let bytesBeforeChunk = completedBytes
            let request = MTPHelperRequest(operation: .upload, uploadFiles: chunk)
            let response = try await perform(
                request: request,
                timeout: operationTimeout(for: request),
                onProgress: { event in
                    // Remap chunk-local fraction into overall multi-chunk progress.
                    let overall: Double
                    if totalBytes > 0 {
                        let within = event.overallFraction * Double(chunkBytes)
                        overall = min(1, max(0, (Double(bytesBeforeChunk) + within) / Double(totalBytes)))
                    } else {
                        overall = (Double(chunkIndex) + event.overallFraction) / Double(max(chunks.count, 1))
                    }
                    onProgress?(
                        MTPProgressEvent(
                            phase: event.phase,
                            itemIndex: chunkIndex * Self.uploadChunkSize + event.itemIndex,
                            itemCount: files.count,
                            itemName: event.itemName,
                            bytesTransferred: event.bytesTransferred,
                            bytesTotal: event.bytesTotal,
                            overallFraction: overall,
                            message: event.message
                        )
                    )
                }
            )
            if let result = response.operationResult {
                completed += result.completedCount
                failures.append(contentsOf: result.failedItems)

                let failedNames = Set(result.failedItems)
                if failedNames.isEmpty, result.completedCount >= chunk.count {
                    completedBytes += chunkBytes
                } else {
                    let succeeded = chunk.filter { !failedNames.contains($0.displayName) }
                    if !succeeded.isEmpty {
                        completedBytes += succeeded.reduce(Int64(0)) {
                            $0 + max(Self.fileSize(atPath: $1.localPath), 0)
                        }
                    } else if result.completedCount > 0, chunk.count > 0 {
                        let ratio = min(1, max(0, Double(result.completedCount) / Double(chunk.count)))
                        completedBytes += Int64(Double(chunkBytes) * ratio)
                    }
                    // Total failure: no byte credit.
                }
            } else if !response.ok {
                failures.append(contentsOf: chunk.map(\.displayName))
                // No byte credit on hard failure.
            }
        }

        let message: String
        if failures.isEmpty {
            message = "\(completed) file(s) uploaded."
        } else {
            message = "\(completed) file(s) uploaded; \(failures.count) failed."
        }
        return DeviceFileOperationResult(completedCount: completed, failedItems: failures, message: message)
    }

    func status() async throws -> MTPToolStatus {
        let response = try await perform(request: MTPHelperRequest(operation: .status), timeout: 15)
        guard let status = response.dependencyStatus else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper did not return diagnostics.")
        }
        return status
    }

    func operationTimeout(for request: MTPHelperRequest) -> TimeInterval {
        switch request.operation {
        case .upload:
            let bytes = request.uploadFiles.reduce(Int64(0)) { total, file in
                total + max(Self.fileSize(atPath: file.localPath), 0)
            }
            // With a warm session, per-item overhead is much lower than cold-start estimates.
            return Self.scaledTimeout(
                base: 60,
                itemCount: request.uploadFiles.count,
                bytes: bytes,
                secondsPerItem: 12,
                secondsPerMiB: 2.0,
                maximum: 3_600
            )
        case .download:
            let bytes = request.files.reduce(Int64(0)) { $0 + max($1.size, 0) }
            return Self.scaledTimeout(
                base: 60,
                itemCount: request.files.count,
                bytes: bytes,
                secondsPerItem: 10,
                secondsPerMiB: 1.25,
                maximum: 3_600
            )
        case .delete:
            return min(600, max(45, 30 + TimeInterval(request.files.count * 4)))
        case .move:
            return 600
        case .status, .detect, .listMusic, .listStorageTree, .storageInfo, .createPlaylist:
            // Warm session makes listing far cheaper; keep headroom for large libraries.
            return request.operation == .listStorageTree ? 180 : 90
        }
    }

    static func scaledTimeout(
        base: TimeInterval,
        itemCount: Int,
        bytes: Int64,
        secondsPerItem: TimeInterval,
        secondsPerMiB: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        let mebibytes = Double(max(bytes, 0)) / 1_048_576
        let estimate = base + TimeInterval(itemCount) * secondsPerItem + mebibytes * secondsPerMiB
        return min(maximum, max(base, estimate))
    }

    private static func fileSize(atPath path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
    }

    private func perform(
        request: MTPHelperRequest,
        timeout: TimeInterval,
        onProgress: MTPTransferProgressHandler? = nil
    ) async throws -> MTPHelperResponse {
        guard let transport else {
            throw DeviceFileSystemError.helperMissing
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let requestData = try encoder.encode(request)

        return try await MTPOperationCoordinator.shared.perform {
            try await self.performWithRetry(
                transport: transport,
                requestData: requestData,
                timeout: timeout,
                onProgress: onProgress
            )
        }
    }

    private func performWithRetry(
        transport: MTPHelperTransport,
        requestData: Data,
        timeout: TimeInterval,
        onProgress: MTPTransferProgressHandler?
    ) async throws -> MTPHelperResponse {
        var lastError: Error?
        for attempt in 1...MTPRetryPolicy.maxAttempts {
            try Task.checkCancellation()
            do {
                let data = try await transport.send(requestData, timeout: timeout, onProgress: onProgress)
                return try Self.decodeResponse(from: data)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let transient = MTPRetryPolicy.isTransientError(error)
                    || (error as? DeviceFileSystemError).map { err -> Bool in
                        if case .helperFailed(let message) = err {
                            return MTPRetryPolicy.isTransientFailureMessage(message)
                                || message.localizedCaseInsensitiveContains("timed out")
                                || message.localizedCaseInsensitiveContains("lost contact")
                                || message.localizedCaseInsensitiveContains("exited before")
                        }
                        return false
                    } ?? false

                guard attempt < MTPRetryPolicy.maxAttempts, transient else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(MTPRetryPolicy.backoffSeconds * Double(attempt) * 1_000_000_000))
            }
        }
        throw lastError ?? DeviceFileSystemError.helperFailed("MTP operation failed after retries.")
    }

    static func decodeResponse(from data: Data) throws -> MTPHelperResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response: MTPHelperResponse
        do {
            if let streamLine = try? decoder.decode(MTPHelperStreamLine.self, from: data),
               let fromStream = streamLine.asResponse {
                response = fromStream
            } else {
                response = try decoder.decode(MTPHelperResponse.self, from: data)
            }
        } catch {
            let prefix = String(decoding: data.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = prefix.isEmpty ? "no output" : "output: \(prefix)"
            throw DeviceFileSystemError.helperFailed(
                "The Garmin helper returned an unreadable response (\(detail))."
            )
        }
        if !response.ok, let error = response.error {
            if error.code == "cancelled" {
                throw CancellationError()
            }
            throw error
        }
        return response
    }

    /// Resolves the `GarminMTPHelper` binary for packaged apps and SwiftPM builds.
    static func locateHelper() -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "GarminMTPHelper") {
            return bundled
        }

        var candidates: [URL] = []
        if let executableURL = Bundle.main.executableURL {
            let directory = executableURL.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("GarminMTPHelper"))
            candidates.append(directory.deletingLastPathComponent().appendingPathComponent("GarminMTPHelper"))
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(currentDirectory.appendingPathComponent(".build/debug/GarminMTPHelper"))
        candidates.append(currentDirectory.appendingPathComponent(".build/release/GarminMTPHelper"))
        candidates.append(currentDirectory.appendingPathComponent("dist/Garmin Music Manager.app/Contents/MacOS/GarminMTPHelper"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
