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

            CommandMenu("File Manager") {
                Button("New Folder") {
                    appModel.fileManagerController.beginNewFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Rename…") {
                    if appModel.fileManagerController.focusedPane == .garmin,
                       let file = appModel.deviceBrowser.selectedFiles.first {
                        appModel.fileManagerController.beginRename(id: file.id, currentName: file.name)
                    } else {
                        appModel.fileManagerController.showRenameSheet = true
                    }
                }
                .keyboardShortcut("\r", modifiers: [])

                Button("Move to Trash / Delete…") {
                    if appModel.fileManagerController.focusedPane == .garmin {
                        appModel.requestDeleteSelectedDeviceFiles()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command])

                Button("Duplicate") {}
                    .keyboardShortcut("d", modifiers: [.command])

                Divider()

                Button("Select All") {
                    if appModel.fileManagerController.focusedPane == .garmin {
                        appModel.deviceBrowser.selectedFileIDs = Set(appModel.deviceBrowser.displayedFiles.map(\.id))
                    }
                }
                .keyboardShortcut("a", modifiers: [.command])

                Button("Copy") {
                    let pane = appModel.fileManagerController.focusedPane
                    if pane == .garmin {
                        let files = appModel.deviceBrowser.selectedFiles
                        appModel.fileManagerCopySelection(
                            from: .garmin,
                            localURLs: [],
                            names: files.map(\.name),
                            deviceIDs: files.map(\.id)
                        )
                    }
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button("Cut") {
                    let pane = appModel.fileManagerController.focusedPane
                    if pane == .garmin {
                        let files = appModel.deviceBrowser.selectedFiles
                        appModel.fileManagerCutSelection(
                            from: .garmin,
                            localURLs: [],
                            names: files.map(\.name),
                            deviceIDs: files.map(\.id)
                        )
                    }
                }
                .keyboardShortcut("x", modifiers: [.command])

                Button("Paste") {
                    let pane = appModel.fileManagerController.focusedPane
                    appModel.fileManagerPaste(into: pane, localFolder: nil)
                }
                .keyboardShortcut("v", modifiers: [.command])

                Divider()

                Button("Get Info") {
                    if appModel.fileManagerController.focusedPane == .garmin,
                       let file = appModel.deviceBrowser.selectedFiles.first {
                        appModel.fileManagerController.presentProperties(FilePropertiesModel.device(file))
                    }
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Quick Look") {
                    if appModel.fileManagerController.focusedPane == .garmin {
                        appModel.quickLookSelectedDeviceFiles()
                    }
                }
                .keyboardShortcut("y", modifiers: [.command])

                Button("Refresh") {
                    appModel.refreshDeviceContents()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Undo") {
                    if let action = appModel.fileManagerController.popUndo() {
                        try? LocalFileOperations.undo(action)
                    }
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!appModel.fileManagerController.canUndo)
            }
        }
        .defaultSize(width: 1180, height: 780)

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
