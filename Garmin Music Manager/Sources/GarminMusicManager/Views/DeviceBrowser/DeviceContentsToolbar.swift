import GarminMusicCore
import SwiftUI

/// Toolbar / primary actions for the On Watch device browser.
struct DeviceContentsToolbar: View {
    @EnvironmentObject private var model: AppModel
    var showsPanelHeader: Bool
    var usesCompactLayout: Bool
    var summaryText: String
    var chips: [String]
    var onRefresh: () -> Void

    private var browser: DeviceBrowserStore { model.deviceBrowser }

    var body: some View {
        VStack(spacing: 0) {
            if showsPanelHeader {
                PanelHeader(
                    side: .garmin,
                    title: "Garmin Library",
                    subtitle: summaryText,
                    systemImage: "applewatch",
                    chips: chips
                ) {
                    trailing
                }
            } else {
                HStack(spacing: 8) {
                    if !chips.isEmpty {
                        ForEach(chips, id: \.self) { chip in
                            StatChip(text: chip, tint: AppTheme.garminTint)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if model.advancedStorageExplorerEnabled {
                Picker("Browse mode", selection: Binding(
                    get: { browser.browseMode },
                    set: { model.switchDeviceBrowseMode(to: $0) }
                )) {
                    Text("Music").tag(DeviceBrowseMode.musicOnly)
                    Text("Storage").tag(DeviceBrowseMode.advancedStorage)
                }
                .pickerStyle(.segmented)
                .frame(width: usesCompactLayout ? 140 : 160)
            }
            deviceActions
        }
    }

    @ViewBuilder
    private var deviceActions: some View {
        if !showsPanelHeader {
            Group {
                HStack(spacing: 8) {
                    addToGarminButton
                    deleteButton
                    Menu {
                        copyToMacButton
                        moveButton
                    } label: {
                        Label("Manage", systemImage: "ellipsis.circle")
                    }
                }
            }
        } else {
            Group {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        refreshButton
                        copyToMacButton
                        addToGarminButton
                        moveButton
                        deleteButton
                    }

                    Menu {
                        refreshButton
                        copyToMacButton
                        addToGarminButton
                        moveButton
                        deleteButton
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(browser.isRefreshing || model.isManagingDeviceFiles)
        .help("Refresh the Garmin file list")
    }

    private var copyToMacButton: some View {
        Button {
            model.copySelectedDeviceFilesToMac()
        } label: {
            Label("Copy to Mac", systemImage: "square.and.arrow.down")
        }
        .disabled(browser.selectedFileIDs.isEmpty || model.isManagingDeviceFiles)
        .help("Copy selected files to this Mac")
    }

    private var addToGarminButton: some View {
        Button {
            model.chooseFilesToUploadToDevice()
        } label: {
            Label("Add to Garmin", systemImage: "plus")
        }
        .disabled(!browser.isConfigured || model.isManagingDeviceFiles || browser.browseMode == .advancedStorage)
        .help("Add music files to the Garmin")
    }

    private var moveButton: some View {
        Button {
            model.startMoveSelectedWithinGarmin()
        } label: {
            Label("Move Within Garmin", systemImage: "folder")
        }
        .disabled(!model.canMoveSelectedDeviceFiles)
        .help("Move selected files to another Garmin folder")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            model.requestDeleteSelectedDeviceFiles()
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(browser.selectedFileIDs.isEmpty || model.isManagingDeviceFiles)
        .help("Delete selected Garmin files")
    }
}
