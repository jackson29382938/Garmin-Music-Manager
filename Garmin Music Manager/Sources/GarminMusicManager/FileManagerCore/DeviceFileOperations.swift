import Foundation
import GarminMusicCore

/// Façade over `DeviceBrowserStore` for File Manager Watch-pane CRUD.
@MainActor
enum DeviceFileOperations {
    static func createFolder(
        named name: String,
        parentPath: String?,
        in store: DeviceBrowserStore
    ) async -> DeviceFileOperationResult? {
        await store.createFolder(named: name, parentPath: parentPath)
    }

    static func rename(
        _ file: DeviceFile,
        to newName: String,
        in store: DeviceBrowserStore
    ) async -> DeviceFileOperationResult? {
        await store.rename(file, to: newName)
    }

    static func deleteSelected(in store: DeviceBrowserStore) async -> DeviceFileOperationResult? {
        await store.deleteSelected()
    }

    static func parentPath(for file: DeviceFile, browseMode: DeviceBrowseMode) -> String {
        let path = file.path
        if let slash = path.lastIndex(of: "/") {
            return String(path[..<slash])
        }
        return browseMode == .advancedStorage ? "" : "Music"
    }
}
