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

        let cacheKey = CacheKey(deviceID: backend.deviceID, mode: browseMode)
        if !force, let cached = cache[cacheKey] {
            apply(cached)
            return
        }

        isRefreshing = true
        lastError = nil
        operation = DeviceOperation(kind: .refresh, phase: browseMode == .advancedStorage ? "Reading Garmin storage" : "Reading Garmin music", progress: nil)

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
        } catch {
            lastError = error.localizedDescription
            statusMessage = files.isEmpty ? error.localizedDescription : "Showing the previous results. Refresh failed: \(error.localizedDescription)"
            operation = DeviceOperation(kind: .refresh, phase: "Refresh failed", progress: nil, lastError: error.localizedDescription)
        }

        isRefreshing = false
    }

    @discardableResult
    func copySelected(to destinationFolder: URL) async -> DeviceFileOperationResult? {
        guard let backend, !selectedFiles.isEmpty else { return nil }
        operation = DeviceOperation(kind: .copy, phase: "Copying selected files", progress: nil)
        do {
            let result = try await backend.download(selectedFiles, to: destinationFolder)
            applyOperationResult(result, kind: .copy, successMessage: "Copy complete.")
            return result
        } catch {
            applyOperationError(error, kind: .copy)
            return nil
        }
    }

    @discardableResult
    func upload(_ uploadFiles: [DeviceUploadFile]) async -> DeviceFileOperationResult? {
        guard let backend, !uploadFiles.isEmpty else { return nil }
        operation = DeviceOperation(kind: .upload, phase: "Uploading files to Garmin", progress: nil)
        do {
            let result = try await backend.upload(uploadFiles)
            applyOperationResult(result, kind: .upload, successMessage: "Upload complete.")
            await refresh(force: true)
            return result
        } catch {
            applyOperationError(error, kind: .upload)
            return nil
        }
    }

    @discardableResult
    func deleteSelected() async -> DeviceFileOperationResult? {
        guard let backend, !selectedFiles.isEmpty else { return nil }
        operation = DeviceOperation(kind: .delete, phase: "Deleting selected files", progress: nil)
        do {
            let result = try await backend.delete(selectedFiles)
            selectedFileIDs.removeAll()
            invalidateCurrentCache()
            applyOperationResult(result, kind: .delete, successMessage: "Delete complete.")
            await refresh(force: true)
            return result
        } catch {
            applyOperationError(error, kind: .delete)
            return nil
        }
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
        lastError = error.localizedDescription
        statusMessage = error.localizedDescription
        operation = DeviceOperation(kind: kind, phase: "Operation failed", progress: nil, lastError: error.localizedDescription)
    }

    private struct CacheKey: Hashable {
        let deviceID: String
        let mode: DeviceBrowseMode
    }
}
