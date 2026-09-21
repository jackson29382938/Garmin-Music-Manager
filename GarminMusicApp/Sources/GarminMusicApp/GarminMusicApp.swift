import DefaultBackend
import SwiftCrossUI

/// Cross-platform entry point. `DefaultBackend` chooses AppKit on macOS,
/// WinUI on Windows, and Gtk on Linux, so this single app renders natively
/// on every desktop platform.
@main
struct GarminMusicApp: App {
    @State var state = AppState()

    var body: some Scene {
        WindowGroup("Garmin Music Manager") {
            ContentView(state: state)
        }
        .defaultSize(width: 1000, height: 700)
    }
}
