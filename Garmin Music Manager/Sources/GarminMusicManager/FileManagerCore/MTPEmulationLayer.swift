import Foundation
import GarminMusicCore

/// Strategies for Watch ops that MTP does not support natively.
enum MTPEmulationKind: String, Sendable {
    case createFolder
    case rename
    case move
    case zipRoundTrip
}

struct MTPEmulationNotice: Sendable {
    var kind: MTPEmulationKind
    var title: String
    var message: String
}

enum MTPEmulationLayer {
    static func notice(for kind: MTPEmulationKind, detail: String? = nil) -> MTPEmulationNotice {
        switch kind {
        case .createFolder:
            return MTPEmulationNotice(
                kind: kind,
                title: "Emulated on MTP",
                message: detail ?? "Creating folders on Garmin uses MTP folder APIs and may be slow."
            )
        case .rename:
            return MTPEmulationNotice(
                kind: kind,
                title: "Emulated rename on MTP",
                message: detail
                    ?? "Garmin MTP rename downloads, re-uploads under the new name, then deletes the original. This uses free space and can take a while."
            )
        case .move:
            return MTPEmulationNotice(
                kind: kind,
                title: "Emulated move on MTP",
                message: detail
                    ?? "In-watch move copies via a temporary Mac folder, then asks before deleting originals."
            )
        case .zipRoundTrip:
            return MTPEmulationNotice(
                kind: kind,
                title: "Emulated archive on MTP",
                message: detail
                    ?? "Zip/unzip on the watch downloads to the Mac, processes locally, then uploads results."
            )
        }
    }
}
