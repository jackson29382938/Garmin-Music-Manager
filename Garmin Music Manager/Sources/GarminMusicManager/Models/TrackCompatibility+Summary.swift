import Foundation
import GarminMusicCore

extension TrackCompatibility {
    var summary: String {
        if messages.isEmpty { return status.rawValue }
        return messages.joined(separator: "; ")
    }
}
