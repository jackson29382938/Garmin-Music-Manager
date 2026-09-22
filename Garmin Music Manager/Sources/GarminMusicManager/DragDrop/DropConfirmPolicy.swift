import Foundation

/// When a drop needs an explicit confirmation sheet.
enum DropConfirmPolicy {
    static let largeFileCountThreshold = 25
    static let largeByteThreshold: Int64 = 200_000_000 // 200 MB

    static func shouldConfirm(
        items: DragItemSet,
        operation: DropOperation,
        context: DropEvaluationContext
    ) -> Bool {
        if operation.isRejected { return false }

        if operation.deletesSource {
            return true
        }

        if context.hasNameCollisions,
           context.overwritePolicy == .replace || context.overwritePolicy == .keepBoth {
            return true
        }

        if let capacity = context.availableCapacity, items.totalByteCount > 0 {
            if items.totalByteCount > capacity {
                return true
            }
            // Tight free space (< 15% headroom after transfer)
            let remaining = capacity - items.totalByteCount
            if remaining < capacity / 10 {
                return true
            }
        }

        if items.itemCount >= largeFileCountThreshold {
            return true
        }

        if items.totalByteCount >= largeByteThreshold {
            return true
        }

        if items.totalByteCount >= context.largeFileWarningBytes {
            return true
        }

        return false
    }

    static func warnings(
        items: DragItemSet,
        operation: DropOperation,
        context: DropEvaluationContext
    ) -> [String] {
        var lines: [String] = []
        if operation.deletesSource {
            lines.append("Source files will be deleted after a successful transfer.")
        }
        if context.hasNameCollisions {
            switch context.overwritePolicy {
            case .replace:
                lines.append("Some files will replace existing items (Overwrite: Replace).")
            case .keepBoth:
                lines.append("Name conflicts will keep both files (rename new).")
            case .skipIdentical:
                lines.append("Identical files will be skipped.")
            }
        }
        if let capacity = context.availableCapacity, items.totalByteCount > capacity {
            lines.append("Selected size exceeds reported free space on the destination.")
        }
        if items.itemCount >= largeFileCountThreshold {
            lines.append("Large selection (\(items.itemCount) items).")
        }
        return lines
    }
}
