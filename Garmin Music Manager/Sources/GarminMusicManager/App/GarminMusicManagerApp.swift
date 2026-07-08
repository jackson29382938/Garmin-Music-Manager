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

                Divider()

                Button("Sync Playlist…") {
                    appModel.prepareSyncPreview()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appModel.canSync)

                Button("Send Selected to Garmin") {
                    appModel.uploadSelectedTracksToDevice()
                }
                .disabled(!appModel.canUploadSelectedTracksToDevice)
            }
        }
        .defaultSize(width: 1180, height: 780)

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
