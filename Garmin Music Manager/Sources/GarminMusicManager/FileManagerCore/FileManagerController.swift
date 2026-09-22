import Foundation
import Combine

/// Shared File Manager command hub (pane focus, clipboard, undo, UI flags).
@MainActor
final class FileManagerController: ObservableObject {
    @Published var focusedPane: FileManagerPane = .mac
    @Published var showHiddenFiles = false
    @Published var recursiveSearch = false
    @Published var viewMode: LocalViewMode = .list
    @Published var sort: LocalFileSort = .name
    @Published var propertiesItem: FilePropertiesModel?
    @Published var showProperties = false
    @Published var renameTargetID: String?
    @Published var renameDraft = ""
    @Published var showNewFolderSheet = false
    @Published var newFolderName = "New Folder"
    @Published var showRenameSheet = false
    @Published var showSyncConfirm = false
    @Published var pendingSyncPlan: DualPaneSyncPlan?
    @Published var showMirrorConfirm = false
    @Published var mirrorAcknowledged = false
    @Published var lastEmulationBanner: String?
    @Published var compareSummary: String?

    let clipboard = FileClipboard()
    let macTabs: FileManagerTabState
    @Published private(set) var undoStack: [LocalUndoAction] = []

    init(initialFolder: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")) {
        macTabs = FileManagerTabState(initial: initialFolder)
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func pushUndo(_ action: LocalUndoAction?) {
        guard let action else { return }
        undoStack.append(action)
        if undoStack.count > 30 {
            undoStack.removeFirst(undoStack.count - 30)
        }
    }

    func popUndo() -> LocalUndoAction? {
        guard !undoStack.isEmpty else { return nil }
        return undoStack.removeLast()
    }

    func presentProperties(_ model: FilePropertiesModel) {
        propertiesItem = model
        showProperties = true
    }

    func beginRename(id: String, currentName: String) {
        renameTargetID = id
        renameDraft = currentName
        showRenameSheet = true
    }

    func beginNewFolder() {
        newFolderName = "New Folder"
        showNewFolderSheet = true
    }

    func presentEmulation(_ notice: MTPEmulationNotice, notify: Bool, presentNotice: (String, String) -> Void) {
        lastEmulationBanner = notice.message
        if notify {
            presentNotice(notice.title, notice.message)
        }
    }

    func clearEmulationBanner() {
        lastEmulationBanner = nil
    }

    func presentSyncPlan(_ plan: DualPaneSyncPlan) {
        pendingSyncPlan = plan
        if plan.action.isDestructive {
            mirrorAcknowledged = false
            showMirrorConfirm = true
        } else {
            showSyncConfirm = true
        }
    }
}
