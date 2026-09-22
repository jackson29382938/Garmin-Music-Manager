import Foundation

struct SyncListingItem: Hashable, Sendable {
    var name: String
    var size: Int64
    var modified: Date?
    var isDirectory: Bool
    var localURL: URL?
    var deviceFileID: String?
}

enum DualPaneSyncAction: String, CaseIterable, Identifiable, Sendable {
    case copyLeftToRight
    case copyRightToLeft
    case syncNewerLeftToRight
    case syncNewerRightToLeft
    case mirrorLeftToRight
    case mirrorRightToLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copyLeftToRight: return "Copy →"
        case .copyRightToLeft: return "Copy ←"
        case .syncNewerLeftToRight: return "Sync newer →"
        case .syncNewerRightToLeft: return "Sync newer ←"
        case .mirrorLeftToRight: return "Mirror →"
        case .mirrorRightToLeft: return "Mirror ←"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .mirrorLeftToRight, .mirrorRightToLeft: return true
        default: return false
        }
    }
}

struct DualPaneSyncPlanItem: Hashable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case copy
        case delete
        case skip
    }

    var id: String { "\(kind.rawValue):\(name)" }
    var kind: Kind
    var name: String
    var size: Int64
    var sourceLocalURL: URL?
    var sourceDeviceFileID: String?
    var reason: String
}

struct DualPaneSyncPlan: Sendable {
    var action: DualPaneSyncAction
    var items: [DualPaneSyncPlanItem]

    var copyCount: Int { items.filter { $0.kind == .copy }.count }
    var deleteCount: Int { items.filter { $0.kind == .delete }.count }
    var totalBytes: Int64 { items.filter { $0.kind == .copy }.reduce(0) { $0 + $1.size } }
}

/// Compares two folder/device listings by name + size (+ optional date).
enum DualPaneSyncPlanner {
    static func plan(
        action: DualPaneSyncAction,
        left: [SyncListingItem],
        right: [SyncListingItem]
    ) -> DualPaneSyncPlan {
        let leftFiles = Dictionary(uniqueKeysWithValues: left.filter { !$0.isDirectory }.map { ($0.name.lowercased(), $0) })
        let rightFiles = Dictionary(uniqueKeysWithValues: right.filter { !$0.isDirectory }.map { ($0.name.lowercased(), $0) })
        var items: [DualPaneSyncPlanItem] = []

        switch action {
        case .copyLeftToRight:
            for (key, src) in leftFiles {
                if rightFiles[key] == nil || rightFiles[key]?.size != src.size {
                    items.append(copyItem(from: src, reason: rightFiles[key] == nil ? "Missing on right" : "Different size"))
                }
            }
        case .copyRightToLeft:
            for (key, src) in rightFiles {
                if leftFiles[key] == nil || leftFiles[key]?.size != src.size {
                    items.append(copyItem(from: src, reason: leftFiles[key] == nil ? "Missing on left" : "Different size"))
                }
            }
        case .syncNewerLeftToRight:
            for (key, src) in leftFiles {
                guard let dst = rightFiles[key] else {
                    items.append(copyItem(from: src, reason: "Missing on right"))
                    continue
                }
                if isNewer(src, than: dst) || src.size != dst.size {
                    items.append(copyItem(from: src, reason: "Newer or different on left"))
                }
            }
        case .syncNewerRightToLeft:
            for (key, src) in rightFiles {
                guard let dst = leftFiles[key] else {
                    items.append(copyItem(from: src, reason: "Missing on left"))
                    continue
                }
                if isNewer(src, than: dst) || src.size != dst.size {
                    items.append(copyItem(from: src, reason: "Newer or different on right"))
                }
            }
        case .mirrorLeftToRight:
            for (key, src) in leftFiles {
                if rightFiles[key] == nil || rightFiles[key]?.size != src.size {
                    items.append(copyItem(from: src, reason: "Mirror from left"))
                }
            }
            for (key, dst) in rightFiles where leftFiles[key] == nil {
                items.append(
                    DualPaneSyncPlanItem(
                        kind: .delete,
                        name: dst.name,
                        size: dst.size,
                        sourceLocalURL: dst.localURL,
                        sourceDeviceFileID: dst.deviceFileID,
                        reason: "Not on left (mirror delete)"
                    )
                )
            }
        case .mirrorRightToLeft:
            for (key, src) in rightFiles {
                if leftFiles[key] == nil || leftFiles[key]?.size != src.size {
                    items.append(copyItem(from: src, reason: "Mirror from right"))
                }
            }
            for (key, dst) in leftFiles where rightFiles[key] == nil {
                items.append(
                    DualPaneSyncPlanItem(
                        kind: .delete,
                        name: dst.name,
                        size: dst.size,
                        sourceLocalURL: dst.localURL,
                        sourceDeviceFileID: dst.deviceFileID,
                        reason: "Not on right (mirror delete)"
                    )
                )
            }
        }

        return DualPaneSyncPlan(action: action, items: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private static func copyItem(from src: SyncListingItem, reason: String) -> DualPaneSyncPlanItem {
        DualPaneSyncPlanItem(
            kind: .copy,
            name: src.name,
            size: src.size,
            sourceLocalURL: src.localURL,
            sourceDeviceFileID: src.deviceFileID,
            reason: reason
        )
    }

    private static func isNewer(_ a: SyncListingItem, than b: SyncListingItem) -> Bool {
        guard let am = a.modified, let bm = b.modified else { return false }
        return am > bm
    }
}
