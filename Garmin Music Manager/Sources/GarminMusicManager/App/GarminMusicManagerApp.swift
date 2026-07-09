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
                Button("Add Files…") {
                    appModel.chooseMusicFiles()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Add Folder…") {
                    appModel.chooseMusicFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Import M3U Playlist…") {
                    appModel.chooseM3UPlaylist()
                }

                Button("Load Apple Music Library…") {
                    appModel.openAppleMusicBrowser()
                }

                Divider()

                Button("Refresh Garmin Devices") {
                    appModel.refreshDevices()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Browse Garmin Library") {
                    appModel.browseGarminMusicLibrary()
                }
                .disabled(!appModel.hasMTPDestination || !appModel.mtpDependencyStatus.isReady)

                Button("Choose Destination Folder…") {
                    appModel.chooseCustomGarminFolder()
                }

                Divider()

                Button("Send to Watch…") {
                    appModel.beginSend()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appModel.canSync)

                Button("Send without Preview") {
                    appModel.quickSendSelected()
                }
                .disabled(!appModel.canUploadSelectedTracksToDevice)

                Button(appModel.retryFailedTransfersTitle) {
                    appModel.retryFailedTransfers()
                }
                .disabled(!appModel.canRetryFailedTransfers)

                Button("Cancel Transfer") {
                    if appModel.isSyncing {
                        appModel.cancelSync()
                    } else {
                        appModel.cancelDeviceOperation()
                    }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!appModel.isSyncing && !appModel.isManagingDeviceFiles && !appModel.isBrowsingDevice)
            }
        }
        .defaultSize(width: 1180, height: 780)

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
