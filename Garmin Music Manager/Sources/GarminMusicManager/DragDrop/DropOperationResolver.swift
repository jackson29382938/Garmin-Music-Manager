import Foundation

/// Resolves copy vs move vs transfer from source, destination, and modifiers.
///
/// Defaults:
/// - Same device (Mac→Mac folder/playlist, Watch→Watch playlist): **move**
/// - Cross device (Mac↔Watch): **copy**
/// - Option/Alt: force copy
/// - Command: force move on cross-device transfers (with confirm)
enum DropOperationResolver {
    static func resolve(
        items: DragItemSet,
        destination: DropDestination,
        modifiers: DropModifierFlags,
        context: DropEvaluationContext
    ) -> DropOperation {
        if let rejection = DropValidator.validate(items: items, destination: destination, context: context) {
            return rejection
        }

        let forceCopy = modifiers.contains(.option)
        let preferMove = modifiers.contains(.command) && !forceCopy

        switch destination {
        case .railTab:
            return .copy // rail only switches tabs

        case .externalFinder:
            if !items.deviceFileIDs.isEmpty {
                return .transferCopy
            }
            return forceCopy ? .copy : .copy

        case .transferQueue:
            return .importExternal

        case .localFolder:
            // Watch → Mac: copy by default; ⌘ = move
            if !items.deviceFileIDs.isEmpty {
                if forceCopy { return .transferCopy }
                return preferMove ? .transferMove : .transferCopy
            }
            // Mac → Mac (same computer): move by default; Option = copy
            if forceCopy { return .copy }
            return .move

        case .deviceMusicRoot, .devicePlaylistFolder:
            // Watch → Watch playlist/folder: always move (Option still copies only for Mac sources)
            if !items.deviceFileIDs.isEmpty {
                if forceCopy {
                    // In-watch "copy" is not a first-class op; keep move semantics.
                    return .move
                }
                return .move
            }
            // Mac / Finder / Apple Music → Watch: copy by default; ⌘ = move
            if forceCopy { return .transferCopy }
            return preferMove ? .transferMove : .transferCopy
        }
    }
}

extension DropOperation {
    /// Overlay text that reflects source→destination direction.
    func dropOverlayLabel(for destination: DropDestination) -> String {
        switch self {
        case .rejected:
            return "Not allowed"
        case .importExternal:
            return "Import here"
        case .copy:
            return "Copy here"
        case .move:
            if case .devicePlaylistFolder = destination {
                return "Move to playlist"
            }
            return "Move here"
        case .transferCopy:
            switch destination {
            case .localFolder, .externalFinder:
                return "Copy to Mac"
            case .deviceMusicRoot, .devicePlaylistFolder:
                return "Copy to Garmin"
            default:
                return "Copy"
            }
        case .transferMove:
            switch destination {
            case .localFolder, .externalFinder:
                return "Move to Mac"
            case .deviceMusicRoot, .devicePlaylistFolder:
                return "Move to Garmin"
            default:
                return "Move"
            }
        }
    }
}
