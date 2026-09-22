import AppKit
import Foundation

enum DropModifierFlagsReader {
    /// Reads current keyboard modifiers at drop time (SwiftUI onDrop does not stream them).
    static func current() -> DropModifierFlags {
        var flags: DropModifierFlags = []
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) { flags.insert(.command) }
        if mods.contains(.option) { flags.insert(.option) }
        return flags
    }
}
