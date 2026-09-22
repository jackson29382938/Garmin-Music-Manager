import Foundation
import SwiftUI

/// Opens a folder after an intentional hover delay during drag.
@MainActor
final class FolderHoverOpenController: ObservableObject {
    @Published private(set) var pendingFolderID: String?
    @Published private(set) var progress: Double = 0

    var delay: TimeInterval = 0.7
    private var task: Task<Void, Never>?
    private var lastOpenedID: String?

    func pointerEntered(folderID: String, open: @escaping () -> Void) {
        if folderID == lastOpenedID {
            return
        }
        if pendingFolderID == folderID { return }
        cancel()
        pendingFolderID = folderID
        progress = 0
        task = Task { [delay] in
            let steps = 14
            let stepDelay = delay / Double(steps)
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.progress = Double(step) / Double(steps)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.lastOpenedID = folderID
                self.pendingFolderID = nil
                self.progress = 0
                open()
            }
        }
    }

    func pointerExited(folderID: String) {
        if pendingFolderID == folderID {
            cancel()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingFolderID = nil
        progress = 0
    }

    func resetOpenedMemory() {
        lastOpenedID = nil
    }
}
