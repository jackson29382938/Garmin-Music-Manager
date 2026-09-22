import Foundation

/// Identifiers for File Manager / On Watch menu and keyboard commands.
enum FileManagerCommand: String, CaseIterable, Identifiable {
    case newFolder
    case rename
    case delete
    case duplicate
    case selectAll
    case copy
    case cut
    case paste
    case getInfo
    case quickLook
    case compress
    case decompress
    case refresh
    case undo
    case comparePanes
    case copyLeftToRight
    case copyRightToLeft
    case syncNewerLeftToRight
    case syncNewerRightToLeft
    case mirrorLeftToRight
    case mirrorRightToLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newFolder: return "New Folder"
        case .rename: return "Rename…"
        case .delete: return "Move to Trash"
        case .duplicate: return "Duplicate"
        case .selectAll: return "Select All"
        case .copy: return "Copy"
        case .cut: return "Cut"
        case .paste: return "Paste"
        case .getInfo: return "Get Info"
        case .quickLook: return "Quick Look"
        case .compress: return "Compress"
        case .decompress: return "Decompress"
        case .refresh: return "Refresh"
        case .undo: return "Undo"
        case .comparePanes: return "Compare Panes"
        case .copyLeftToRight: return "Copy →"
        case .copyRightToLeft: return "Copy ←"
        case .syncNewerLeftToRight: return "Sync Newer →"
        case .syncNewerRightToLeft: return "Sync Newer ←"
        case .mirrorLeftToRight: return "Mirror →"
        case .mirrorRightToLeft: return "Mirror ←"
        }
    }
}
