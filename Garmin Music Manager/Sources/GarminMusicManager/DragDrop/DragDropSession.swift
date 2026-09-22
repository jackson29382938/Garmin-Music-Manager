import Foundation
import SwiftUI

/// Shared drag-session state for File Manager, On Watch, and the left rail.
@MainActor
final class DragDropSession: ObservableObject {
    @Published var activeItems: DragItemSet = .empty
    @Published var isDragging = false
    @Published var highlightedRailMode: AppMode?
    @Published var highlightDropZone = false
    @Published var pendingConfirm: PendingDropRequest?
    @Published var hoverOpenFolderID: String?
    @Published var hoverOpenProgress: Double = 0

    /// After dropping on a rail tab, destination views pulse their drop zone.
    @Published var pendingRailHighlightMode: AppMode?

    func beginDrag(_ items: DragItemSet) {
        activeItems = items
        isDragging = !items.isEmpty
    }

    func endDrag() {
        isDragging = false
        activeItems = .empty
        highlightedRailMode = nil
        hoverOpenFolderID = nil
        hoverOpenProgress = 0
    }

    func requestRailSwitch(to mode: AppMode) {
        pendingRailHighlightMode = mode
        highlightDropZone = true
    }

    func consumeRailHighlight(for mode: AppMode) -> Bool {
        guard pendingRailHighlightMode == mode else { return false }
        pendingRailHighlightMode = nil
        return true
    }

    func clearDropZoneHighlight() {
        highlightDropZone = false
    }
}
