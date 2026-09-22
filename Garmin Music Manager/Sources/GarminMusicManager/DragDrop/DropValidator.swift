import Foundation

/// Pure validation for drag-and-drop destinations.
enum DropValidator {
    static func validate(
        items: DragItemSet,
        destination: DropDestination,
        context: DropEvaluationContext
    ) -> DropOperation? {
        // Returns nil when valid (operation resolved separately); otherwise rejected.
        if items.isEmpty {
            return .rejected("Nothing to drop")
        }
        if context.isBusy {
            return .rejected("Busy — wait for the current operation")
        }

        switch destination {
        case .railTab:
            // Rail only switches tabs; always allowed while dragging supported content.
            return nil

        case .externalFinder:
            if items.sourceKind == .device || !items.deviceFileIDs.isEmpty {
                // Export requires download-first; allowed as transfer copy out.
                return nil
            }
            if items.localURLs.isEmpty {
                return .rejected("Nothing to export")
            }
            return nil

        case .transferQueue:
            if items.localURLs.isEmpty && items.deviceFileIDs.isEmpty {
                return .rejected("Nothing to import")
            }
            return nil

        case .localFolder(let folder):
            if context.isSameLocalFolder, items.sourceKind == .localFolder || items.sourceKind == .externalFinder {
                return .rejected("Same folder")
            }
            if !items.deviceFileIDs.isEmpty {
                guard context.deviceConfigured || context.deviceConnected else {
                    return .rejected("Watch not connected")
                }
                return nil
            }
            if items.localURLs.isEmpty {
                return .rejected("Nothing to drop")
            }
            // Prevent dropping a folder into itself / descendant.
            for url in items.localURLs {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    let source = url.standardizedFileURL.path
                    let dest = folder.standardizedFileURL.path
                    if dest == source || dest.hasPrefix(source + "/") {
                        return .rejected("Can't move a folder into itself")
                    }
                }
            }
            return nil

        case .deviceMusicRoot, .devicePlaylistFolder:
            guard context.deviceConfigured || context.deviceConnected else {
                return .rejected("Watch not connected")
            }
            if !items.deviceFileIDs.isEmpty {
                // In-watch relocate is allowed (playlist/folder targets).
                return nil
            }
            if items.localURLs.isEmpty {
                return .rejected("Nothing to upload")
            }
            if let capacity = context.availableCapacity,
               items.totalByteCount > 0,
               items.totalByteCount > capacity,
               context.storageExceedPolicy == .blockSend {
                return .rejected("Not enough free space on the watch")
            }
            return nil
        }
    }

    static func isAcceptable(
        items: DragItemSet,
        destination: DropDestination,
        context: DropEvaluationContext
    ) -> Bool {
        if let rejection = validate(items: items, destination: destination, context: context) {
            return !rejection.isRejected
        }
        return true
    }
}
