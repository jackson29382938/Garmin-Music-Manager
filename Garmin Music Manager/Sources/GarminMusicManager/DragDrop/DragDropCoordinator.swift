import AppKit
import Foundation
import GarminMusicCore

/// Executes validated drops using existing AppModel / device APIs (no parallel transfer stack).
@MainActor
final class DragDropCoordinator {
    private let scanner = MusicScanner()

    struct Hosts {
        var uploadFilesToDevice: ([URL]) -> Void
        var downloadDeviceFiles: (_ ids: [String], _ folder: URL) -> Void
        var deleteSelectedDeviceFiles: () -> Void
        var selectDeviceFileIDs: (Set<String>) -> Void
        var startMoveWithinGarmin: () -> Void
        var moveWithinGarminToPlaylist: (String) -> Void
        var addFilesToQueue: ([URL]) async -> Void
        var presentNotice: (UserNoticeKind, String, String) -> Void
        var requestDeleteConfirmationAfterDownload: ([String]) -> Void
        var isDeviceConfigured: () -> Bool
        var availableCapacity: () -> Int64?
        var syncOverwritePolicy: () -> OverwritePolicy
        var largeFileWarningBytes: () -> Int64
        var storageExceedPolicy: () -> StorageExceedPolicy
        var isBusy: () -> Bool
        var destinationIsReady: () -> Bool
    }

    private let hosts: Hosts

    init(hosts: Hosts) {
        self.hosts = hosts
    }

    func evaluationContext(
        items: DragItemSet,
        destination: DropDestination,
        localDestinationFolder: URL? = nil
    ) -> DropEvaluationContext {
        var sameFolder = false
        var sameVolume = true
        var collisions = false

        if case .localFolder(let folder) = destination {
            if items.sourceKind == .localFolder || items.sourceKind == .externalFinder {
                let parentPaths = Set(items.localURLs.map { $0.deletingLastPathComponent().standardizedFileURL.path })
                sameFolder = parentPaths.count == 1 && parentPaths.contains(folder.standardizedFileURL.path)
            }
            sameVolume = items.localURLs.allSatisfy { url in
                url.standardizedFileURL.pathComponents.first == folder.standardizedFileURL.pathComponents.first
                    || volumeID(of: url) == volumeID(of: folder)
            }
            collisions = items.localURLs.contains { url in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(url.lastPathComponent).path)
            }
        }

        return DropEvaluationContext(
            deviceConnected: hosts.destinationIsReady() || hosts.isDeviceConfigured(),
            deviceConfigured: hosts.isDeviceConfigured(),
            availableCapacity: hosts.availableCapacity(),
            isBusy: hosts.isBusy(),
            overwritePolicy: hosts.syncOverwritePolicy(),
            largeFileWarningBytes: hosts.largeFileWarningBytes(),
            storageExceedPolicy: hosts.storageExceedPolicy(),
            isSameLocalFolder: sameFolder,
            sameVolumeAsDestination: sameVolume,
            hasNameCollisions: collisions,
            collidingByteCount: 0
        )
    }

    func propose(
        items: DragItemSet,
        destination: DropDestination,
        modifiers: DropModifierFlags = DropModifierFlagsReader.current()
    ) -> DropOperation {
        let context = evaluationContext(items: items, destination: destination)
        return DropOperationResolver.resolve(
            items: items,
            destination: destination,
            modifiers: modifiers,
            context: context
        )
    }

    /// Returns a pending confirm request when needed; otherwise executes immediately.
    @discardableResult
    func handleDrop(
        items: DragItemSet,
        destination: DropDestination,
        destinationLabel: String,
        sourceLabel: String,
        modifiers: DropModifierFlags = DropModifierFlagsReader.current(),
        session: DragDropSession
    ) -> Bool {
        let context = evaluationContext(items: items, destination: destination)
        let operation = DropOperationResolver.resolve(
            items: items,
            destination: destination,
            modifiers: modifiers,
            context: context
        )
        guard !operation.isRejected else {
            if case .rejected(let reason) = operation {
                hosts.presentNotice(.warning, "Drop not allowed", reason)
            }
            return false
        }

        if case .railTab = destination {
            return false
        }

        if DropConfirmPolicy.shouldConfirm(items: items, operation: operation, context: context) {
            session.pendingConfirm = PendingDropRequest(
                items: items,
                destination: destination,
                operation: operation,
                destinationLabel: destinationLabel,
                sourceLabel: sourceLabel,
                warnings: DropConfirmPolicy.warnings(items: items, operation: operation, context: context)
            )
            return true
        }

        execute(items: items, destination: destination, operation: operation)
        return true
    }

    func confirmPending(_ request: PendingDropRequest, session: DragDropSession) {
        session.pendingConfirm = nil
        execute(items: request.items, destination: request.destination, operation: request.operation)
    }

    func cancelPending(session: DragDropSession) {
        session.pendingConfirm = nil
    }

    func execute(items: DragItemSet, destination: DropDestination, operation: DropOperation) {
        switch (destination, operation) {
        case (.localFolder(let folder), .copy), (.localFolder(let folder), .importExternal):
            performLocalCopy(items.localURLs, to: folder)

        case (.localFolder(let folder), .move):
            performLocalMove(items.localURLs, to: folder)

        case (.localFolder(let folder), .transferCopy):
            hosts.downloadDeviceFiles(items.deviceFileIDs, folder)

        case (.localFolder(let folder), .transferMove):
            hosts.downloadDeviceFiles(items.deviceFileIDs, folder)
            hosts.requestDeleteConfirmationAfterDownload(items.deviceFileIDs)

        case (.deviceMusicRoot, .transferCopy), (.deviceMusicRoot, .copy), (.deviceMusicRoot, .importExternal):
            uploadExpanded(items.localURLs)

        case (.deviceMusicRoot, .transferMove):
            uploadExpanded(items.localURLs)
            // Deleting Mac sources after upload is confirmed via DropConfirmPolicy; perform best-effort trash.
            trashLocalSources(items.localURLs)

        case (.devicePlaylistFolder(let name), .move) where !items.deviceFileIDs.isEmpty:
            hosts.selectDeviceFileIDs(Set(items.deviceFileIDs))
            hosts.moveWithinGarminToPlaylist(name)

        case (.devicePlaylistFolder, .transferCopy), (.devicePlaylistFolder, .transferMove),
             (.devicePlaylistFolder, .copy):
            // Playlist-targeted Mac drops still upload to music root; playlist membership uses existing move UI.
            uploadExpanded(items.localURLs)
            if case .devicePlaylistFolder(let name) = destination, operation == .transferMove || operation == .move {
                hosts.selectDeviceFileIDs(Set(items.deviceFileIDs))
                hosts.moveWithinGarminToPlaylist(name)
            }

        case (.transferQueue, .importExternal), (.transferQueue, .copy):
            Task {
                await hosts.addFilesToQueue(expand(items.localURLs))
            }

        case (.deviceMusicRoot, .move) where !items.deviceFileIDs.isEmpty:
            hosts.selectDeviceFileIDs(Set(items.deviceFileIDs))
            hosts.startMoveWithinGarmin()

        default:
            hosts.presentNotice(.warning, "Drop not handled", "This drop combination is not supported yet.")
        }
    }

    // MARK: - Local FS

    private func expand(_ urls: [URL]) -> [URL] {
        scanner.expandImportURLs(urls).audioURLs
    }

    private func uploadExpanded(_ urls: [URL]) {
        let audio = expand(urls)
        guard !audio.isEmpty else {
            hosts.presentNotice(.warning, "Nothing to upload", "No supported audio files in the selection.")
            return
        }
        hosts.uploadFilesToDevice(audio)
    }

    private func performLocalCopy(_ urls: [URL], to folder: URL) {
        var copied = 0
        var failed = 0
        for url in urls {
            let dest = uniqueDestination(for: url.lastPathComponent, in: folder)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                copied += 1
            } catch {
                failed += 1
            }
        }
        if failed == 0 {
            hosts.presentNotice(.success, "Copied", "Copied \(copied) item(s) to \(folder.lastPathComponent).")
        } else {
            hosts.presentNotice(.warning, "Copy finished with errors", "Copied \(copied), failed \(failed).")
        }
    }

    private func performLocalMove(_ urls: [URL], to folder: URL) {
        var moved = 0
        var failed = 0
        for url in urls {
            let dest = uniqueDestination(for: url.lastPathComponent, in: folder)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                moved += 1
            } catch {
                // Fall back to copy+delete
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    try FileManager.default.removeItem(at: url)
                    moved += 1
                } catch {
                    failed += 1
                }
            }
        }
        if failed == 0 {
            hosts.presentNotice(.success, "Moved", "Moved \(moved) item(s) to \(folder.lastPathComponent).")
        } else {
            hosts.presentNotice(.warning, "Move finished with errors", "Moved \(moved), failed \(failed).")
        }
    }

    private func trashLocalSources(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.recycle([url], completionHandler: nil)
        }
    }

    private func uniqueDestination(for fileName: String, in folder: URL) -> URL {
        let policy = hosts.syncOverwritePolicy()
        let candidate = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        switch policy {
        case .replace:
            return candidate
        case .skipIdentical, .keepBoth:
            return FileNameCollision.keepBothURL(for: fileName, in: folder)
        }
    }

    private func volumeID(of url: URL) -> ObjectIdentifier? {
        guard let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey]),
              let id = values.volumeIdentifier as? NSObject else { return nil }
        return ObjectIdentifier(id)
    }
}

enum FileNameCollision {
    static func keepBothURL(for fileName: String, in folder: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            index += 1
        }
    }
}
