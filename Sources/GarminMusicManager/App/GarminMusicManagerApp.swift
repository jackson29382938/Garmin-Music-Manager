import AppKit
import SwiftUI

@main
struct GarminMusicManagerApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 560, idealWidth: 1000, minHeight: 460, idealHeight: 680)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Garmin Devices") {
                    appModel.refreshDevices()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
