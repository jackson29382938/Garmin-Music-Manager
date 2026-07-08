import Combine
import Foundation
import GarminMusicCore

@MainActor
final class DeviceBrowserStore: ObservableObject {
    @Published var files: [DeviceFile] = []
    @Published var collections: [DeviceCollection] = [
        DeviceCollection(id: "all-music", name: "All Music", kind: .allMusic, fileIDs: [])
    ]
    @Published var storageInfo: DeviceStorageInfo?
    @Published var selectedFileIDs: Set<String> = []
    @Published var selectedCollectionID = "all-music"
    @Published var searchText = ""
    @Published var sortOrder = DeviceFileSort.nameAscending
    @Published var browseMode: DeviceBrowseMode = .musicOnly
    @Published var isRefreshing = false
    @Published var operation: DeviceOperation?
    @Published var lastError: String?
    @Published var statusMessage: String?
    @Published var deviceName: String?

    private var backend: DeviceFileSystem?
    private var cache: [CacheKey: DeviceFileSystemSnapshot] = [:]

    var backendKind: DeviceBackendKind? {
        backend?.backendKind
    }

    var isConfigured: Bool {
        backend != nil
    }

    var supportsMove: Bool {
        backend?.supportsMove == true
    }

    var selectedFiles: [DeviceFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    var selectedCollection: DeviceCollection? {
        collections.first { $0.id == selectedCollectionID }
    }

    var unmatchedItemsForSelectedCollection: [String] {
        selectedCollection?.unmatchedItems ?? []
    }

    var displayedFiles: [DeviceFile] {
        var visible = collectionFilteredFiles

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            visible = visible.filter { file in
                file.name.lowercased().contains(query)
                    || file.path.lowercased().contains(query)
                    || (file.audioMetadata?.artist?.lowercased().contains(query) ?? false)
                    || (file.audioMetadata?.album?.lowercased().contains(query) ?? false)
            }
        }

        switch sortOrder {
        case .nameAscending:
            return visible.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return visible.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .sizeAscending:
            return visible.sorted { $0.size < $1.size }
        case .sizeDescending:
            return visible.sorted { $0.size > $1.size }
        case .folderAscending:
            return visible.sorted {
                let lhs = $0.locationDescription
                let rhs = $1.locationDescription
                if lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }

    func configure(backend: DeviceFileSystem) {
        if self.backend?.deviceID != backend.deviceID {
            selectedFileIDs.removeAll()
            selectedCollectionID = browseMode == .advancedStorage ? "all-storage" : "all-music"
            lastError = nil
            statusMessage = nil
        }
        self.backend = backend
        deviceName = backend.displayName
    }

    func clear(message: String) {
        cache.removeAll()
        backend = nil
        files = []
        collections = [DeviceCollection(id: "all-music", name: "All Music", kind: .allMusic, fileIDs: [])]
        storageInfo = nil
        selectedFileIDs.removeAll()
        selectedCollectionID = "all-music"
        isRefreshing = false
        operation = nil
        lastError = nil
        statusMessage = message
        deviceName = nil
    }

    func setBrowseMode(_ mode: DeviceBrowseMode, advancedEnabled: Bool) {
        let resolvedMode: DeviceBrowseMode = advancedEnabled ? mode : .musicOnly
        guard browseMode != resolvedMode else { return }
        browseMode = resolvedMode
        selectedCollectionID = resolvedMode == .advancedStorage ? "all-storage" : "all-music"
        selectedFileIDs.removeAll()
    }

    func refresh(force: Bool = false) async {
        guard let backend else {
            clear(message: "Connect a Garmin over USB or choose a destination folder to browse existing audio files.")
            return
        }

        if isRefreshing && !force {
            return
        }

        let cacheKey = CacheKey(deviceID: backend.deviceID, mode: browseMode)
        if !force, let cached = cache[cacheKey] {
            apply(cached)
            return
        }

        isRefreshing = true
        lastError = nil
        operation = DeviceOperation(
            kind: .refresh,
            phase: browseMode == .advancedStorage ? "Reading Garmin storage" : "Reading Garmin music",
            progress: nil,
            canCancel: backend.backendKind == .mtp
        )

        do {
            let snapshot: DeviceFileSystemSnapshot
            switch browseMode {
            case .musicOnly:
                snapshot = try await backend.listMusic()
            case .advancedStorage:
                snapshot = try await backend.listStorageTree()
            }
            cache[cacheKey] = snapshot
            apply(snapshot)
            operation = nil
        } catch is CancellationError {
            statusMessage = files.isEmpty ? "Cancelled." : "Showing the previous results."
            operation = nil
        } catch {
            lastError = error.localizedDescription
            statusMessage = files.isEmpty ? error.localizedDescription : "Showing the previous results. Refresh failed: \(error.localizedDescription)"
            // statusMessage/lastError carry the failure; a lingering operation
            // banner would look like the refresh is still running.
            operation = nil
        }

        isRefreshing = false
    }

    @discardableResult
    func copySelected(to destinationFolder: URL) async -> DeviceFileOperationResult? {
        guard let backend, !selectedFiles.isEmpty else { return nil }
        operation = DeviceOperation(kind: .copy, phase: "Copying selected files", progress: 0, canCancel: backend.backendKind == .mtp)
        do {
            let result = try await backend.download(selectedFiles, to: destinationFolder, onProgress: { [weak self] event in
                Task { @MainActor in
                    self?.applyTransferProgress(event, kind: .copy)
                }
            })
            applyOperationResult(result, kind: .copy, successMessage: "Copy complete.")
            return result
        } catch {
            applyOperationError(error, kind: .copy)
            return nil
        }
    }

    @discardableResult
    func upload(
        _ uploadFiles: [DeviceUploadFile],
        syncSettings: SyncSettings? = nil,
        refreshAfter: Bool = true,
        onProgress: MTPTransferProgressHandler? = nil
    ) async -> DeviceFileOperationResult? {
        guard let backend, !uploadFiles.isEmpty else { return nil }
        operation = DeviceOperation(
            kind: .upload,
            phase: "Uploading files to Garmin",
            progress: 0,
            canCancel: backend.backendKind == .mtp
        )
        do {
            let result = try await backend.upload(uploadFiles, syncSettings: syncSettings, onProgress: { [weak self] event in
                onProgress?(event)
                Task { @MainActor in
                    self?.applyTransferProgress(event, kind: .upload)
                }
            })
            applyOperationResult(result, kind: .upload, successMessage: "Upload complete.")
            if refreshAfter {
                await refresh(force: true)
            } else {
                invalidateCurrentCache()
            }
            return result
        } catch {
            applyOperationError(error, kind: .upload)
            return nil
        }
    }

    private func applyTransferProgress(_ event: MTPProgressEvent, kind: DeviceOperationKind) {
        operation = DeviceOperation(
            kind: kind,
            phase: event.displayMessage,
            progress: event.overallFraction,
            canCancel: backendKind == .mtp
        )
    }

    @discardableResult
    func deleteSelected() async -> DeviceFileOperationResult? {
        await delete(selectedFiles)
    }

    @discardableResult
    func delete(_ files: [DeviceFile], refreshAfter: Bool = true) async -> DeviceFileOperationResult? {
        guard let backend, !files.isEmpty else { return nil }
        operation = DeviceOperation(kind: .delete, phase: "Deleting selected files", progress: nil, canCancel: backend.backendKind == .mtp)
        do {
            let result = try await backend.delete(files)
            selectedFileIDs.removeAll()
            invalidateCurrentCache()
            applyOperationResult(result, kind: .delete, successMessage: "Delete complete.")
            if refreshAfter {
                await refresh(force: true)
            }
            return result
        } catch {
            applyOperationError(error, kind: .delete)
            return nil
        }
    }

    @discardableResult
    func copySelectedWithinMTP(to target: GarminFolderTarget) async -> DeviceFileOperationResult? {
        guard let backend, backend.backendKind == .mtp else {
            applyOperationError(
                DeviceFileSystemError.unsupported("This Garmin connection does not need the MTP move fallback."),
                kind: .move
            )
            return nil
        }

        let sourceFiles = selectedFiles.filter { $0.type != .folder }
        guard !sourceFiles.isEmpty else { return nil }

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarminMusicManager-mtp-move-\(UUID().uuidString)", isDirectory: true)
        operation = DeviceOperation(kind: .move, phase: "Copying selected files within Garmin", progress: nil)

        var uploaded: [(file: DeviceFile, targetPath: String)] = []
        var failures: [String] = []

        do {
            try FileManager.default.createDirectory(
                at: tempFolder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: tempFolder) }

            let before = Set((try? FileManager.default.contentsOfDirectory(
                at: tempFolder,
                includingPropertiesForKeys: nil
            )) ?? [])

            let downloadResult = try await backend.download(sourceFiles, to: tempFolder, onProgress: { [weak self] event in
                Task { @MainActor in
                    self?.applyTransferProgress(
                        MTPProgressEvent(
                            phase: "download",
                            itemIndex: event.itemIndex,
                            itemCount: event.itemCount,
                            itemName: event.itemName,
                            bytesTransferred: event.bytesTransferred,
                            bytesTotal: event.bytesTotal,
                            overallFraction: event.overallFraction * 0.5,
                            message: event.message.map { "Move: \($0)" }
                        ),
                        kind: .move
                    )
                }
            })
            failures.append(contentsOf: downloadResult.failedItems)

            var downloaded = downloadedFiles(in: tempFolder, excluding: before)
            var uploadRequests: [DeviceUploadFile] = []
            var uploadSources: [(file: DeviceFile, targetPath: String)] = []
            let failedDownloads = Set(downloadResult.failedItems)

            for file in sourceFiles where !failedDownloads.contains(file.name) {
                guard let localURL = takeDownloadedFile(matching: file, from: &downloaded) else {
                    failures.append(file.name)
                    continue
                }

                let targetPath = target.remotePath(for: file.name)
                let metadata = file.audioMetadata ?? DeviceAudioMetadata(
                    title: (file.name as NSString).deletingPathExtension
                )
                uploadRequests.append(DeviceUploadFile(
                    localPath: localURL.path,
                    remotePath: targetPath,
                    displayName: file.name,
                    metadata: metadata
                ))
                uploadSources.append((file, targetPath))
            }

            if !uploadRequests.isEmpty {
                let uploadResult = try await backend.upload(uploadRequests, syncSettings: nil, onProgress: { [weak self] event in
                    Task { @MainActor in
                        self?.applyTransferProgress(
                            MTPProgressEvent(
                                phase: "upload",
                                itemIndex: event.itemIndex,
                                itemCount: event.itemCount,
                                itemName: event.itemName,
                                bytesTransferred: event.bytesTransferred,
                                bytesTotal: event.bytesTotal,
                                overallFraction: 0.5 + event.overallFraction * 0.5,
                                message: event.message.map { "Move: \($0)" }
                            ),
                            kind: .move
                        )
                    }
                })
                failures.append(contentsOf: uploadResult.failedItems)
                let failedUploads = Set(uploadResult.failedItems)
                for upload in uploadSources where !failedUploads.contains(upload.file.name) {
                    uploaded.append(upload)
                }
            }
        } catch {
            applyOperationError(error, kind: .move)
            return nil
        }

        invalidateCurrentCache()
        await refresh(force: true)

        for upload in uploaded where !containsUploadedCopy(upload.file, at: upload.targetPath) {
            failures.append(upload.file.name)
        }

        let uniqueFailures = Array(Set(failures)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let failedNames = Set(uniqueFailures)
        let completedCount = uploaded.filter { !failedNames.contains($0.file.name) }.count
        let result = DeviceFileOperationResult(
            completedCount: completedCount,
            failedItems: uniqueFailures,
            message: resultMessage(action: "copied within Garmin", count: completedCount, failures: uniqueFailures.count)
        )
        applyOperationResult(result, kind: .move, successMessage: "Copy within Garmin complete.")
        return result
    }

    @discardableResult
    func moveSelected(to destinationFolder: URL) async -> DeviceFileOperationResult? {
        guard let backend, !selectedFiles.isEmpty else { return nil }
        guard backend.supportsMove else {
            applyOperationError(
                DeviceFileSystemError.unsupported("Move is disabled for this Garmin connection. Copy to Mac, delete, or re-sync instead."),
                kind: .move
            )
            return nil
        }

        operation = DeviceOperation(kind: .move, phase: "Moving selected files", progress: nil)
        do {
            let result = try await backend.move(selectedFiles, to: destinationFolder)
            selectedFileIDs.removeAll()
            invalidateCurrentCache()
            applyOperationResult(result, kind: .move, successMessage: "Move complete.")
            await refresh(force: true)
            return result
        } catch {
            applyOperationError(error, kind: .move)
            return nil
        }
    }

    func invalidateCurrentCache() {
        guard let backend else { return }
        cache.removeValue(forKey: CacheKey(deviceID: backend.deviceID, mode: browseMode))
    }

    func clearCachedSnapshots() {
        cache.removeAll()
    }

    private var collectionFilteredFiles: [DeviceFile] {
        guard let collection = selectedCollection else { return files }
        if collection.kind == .allMusic || collection.id == "all-storage" {
            return files
        }
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        return collection.fileIDs.compactMap { filesByID[$0] }
    }

    private func apply(_ snapshot: DeviceFileSystemSnapshot) {
        files = snapshot.files
        collections = snapshot.collections.isEmpty
            ? [DeviceCollection(id: browseMode == .advancedStorage ? "all-storage" : "all-music", name: browseMode == .advancedStorage ? "All Storage" : "All Music", kind: browseMode == .advancedStorage ? .folder : .allMusic, fileIDs: snapshot.files.map(\.id))]
            : snapshot.collections
        storageInfo = snapshot.storageInfo
        deviceName = snapshot.deviceName ?? deviceName
        statusMessage = snapshot.diagnosticMessage
        lastError = nil

        let validIDs = Set(files.map(\.id))
        selectedFileIDs = selectedFileIDs.intersection(validIDs)
        if !collections.contains(where: { $0.id == selectedCollectionID }) {
            selectedCollectionID = browseMode == .advancedStorage ? "all-storage" : "all-music"
        }
    }

    private func applyOperationResult(_ result: DeviceFileOperationResult, kind: DeviceOperationKind, successMessage: String) {
        if result.failedItems.isEmpty {
            lastError = nil
            statusMessage = result.message ?? successMessage
            operation = nil
        } else {
            let message = result.message ?? "\(result.failedItems.count) file(s) failed."
            lastError = message
            statusMessage = message
            operation = DeviceOperation(kind: kind, phase: "Partial success", progress: nil, lastError: message)
        }
    }

    private func applyOperationError(_ error: Error, kind: DeviceOperationKind) {
        if error is CancellationError {
            lastError = nil
            statusMessage = "Cancelled."
            operation = nil
            return
        }
        lastError = error.localizedDescription
        statusMessage = error.localizedDescription
        operation = DeviceOperation(kind: kind, phase: "Operation failed", progress: nil, lastError: error.localizedDescription)
    }

    private func downloadedFiles(in folder: URL, excluding before: Set<URL>) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { !before.contains($0) }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func takeDownloadedFile(matching source: DeviceFile, from candidates: inout [URL]) -> URL? {
        guard !candidates.isEmpty else { return nil }

        let expectedName = FileNameSanitizer.sanitizeFileName(source.name, fallback: "Garmin Track")
        let expectedStem = (expectedName as NSString).deletingPathExtension.lowercased()
        let expectedExtension = (expectedName as NSString).pathExtension.lowercased()

        let bestMatch = candidates.indices.min { lhs, rhs in
            downloadedMatchScore(candidates[lhs], source: source, expectedStem: expectedStem, expectedExtension: expectedExtension)
                < downloadedMatchScore(candidates[rhs], source: source, expectedStem: expectedStem, expectedExtension: expectedExtension)
        }

        guard let index = bestMatch else { return nil }
        guard downloadedMatchScore(candidates[index], source: source, expectedStem: expectedStem, expectedExtension: expectedExtension) < 5 else {
            return nil
        }
        let url = candidates[index]
        candidates.remove(at: index)
        return url
    }

    private func downloadedMatchScore(
        _ url: URL,
        source: DeviceFile,
        expectedStem: String,
        expectedExtension: String
    ) -> Int {
        let size = fileSize(at: url)
        let sizeMatches = source.size <= 0 || size <= 0 || size == source.size
        let name = url.lastPathComponent.lowercased()
        let stem = (url.lastPathComponent as NSString).deletingPathExtension.lowercased()
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        let extensionMatches = expectedExtension.isEmpty || ext == expectedExtension
        let exactName = name == source.name.lowercased()
        let expectedName = stem == expectedStem || stem.hasPrefix("\(expectedStem) ")

        switch (sizeMatches, extensionMatches, exactName, expectedName) {
        case (true, true, true, _):
            return 0
        case (true, true, _, true):
            return 1
        case (true, _, _, _):
            return 2
        case (_, true, true, _):
            return 3
        case (_, true, _, true):
            return 4
        default:
            return 5
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
    }

    private func containsUploadedCopy(_ source: DeviceFile, at targetPath: String) -> Bool {
        let normalizedTarget = targetPath.lowercased()
        let targetFolder = (targetPath as NSString).deletingLastPathComponent.lowercased()
        return files.contains { candidate in
            guard candidate.type != .folder else { return false }
            let pathMatches = candidate.path.lowercased() == normalizedTarget
                || (candidate.name.localizedCaseInsensitiveCompare(source.name) == .orderedSame
                    && candidate.path.lowercased().hasPrefix(targetFolder + "/"))
            let sizeMatches = source.size <= 0 || candidate.size <= 0 || candidate.size == source.size
            return pathMatches && sizeMatches
        }
    }

    private func resultMessage(action: String, count: Int, failures: Int) -> String {
        if failures == 0 {
            return "\(count) file(s) \(action)."
        }
        return "\(count) file(s) \(action); \(failures) failed."
    }

    private struct CacheKey: Hashable {
        let deviceID: String
        let mode: DeviceBrowseMode
    }
}
