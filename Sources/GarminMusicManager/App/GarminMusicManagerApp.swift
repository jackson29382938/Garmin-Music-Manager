import AppKit
import SwiftUI

@main
struct GarminMusicManagerApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 860, idealWidth: 1180, minHeight: 600, idealHeight: 780)
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
