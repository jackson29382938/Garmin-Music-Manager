import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dual-pane File Manager: Garmin library (left) and Mac folders / Apple Music (right).
struct FileManagerView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var folderBrowser = LocalFolderBrowserStore()
    @State private var macMode: FileManagerMacMode = .folders
    @State private var didRestorePersistedState = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                garminPane
                    .frame(minWidth: 320)
                macPane
                    .frame(minWidth: 320)
            }
        }
        .onAppear {
            if !didRestorePersistedState {
                restorePersistedMacState()
                didRestorePersistedState = true
            }
            ensureLibraryLoaded()
        }
        .onChange(of: macMode) { _, newMode in
            persistMacMode(newMode)
            if newMode == .appleMusic {
                ensureAppleMusicLoaded()
            }
        }
        .onChange(of: folderBrowser.currentFolder) { _, folder in
            persistFolder(folder)
        }
    }

    // MARK: - Garmin pane

    private var garminPane: some View {
        VStack(spacing: 0) {
            PanelHeader(
                side: .garmin,
                title: "Garmin",
                subtitle: model.destinationIsReady
                    ? model.garminLibraryLocationDescription
                    : "Connect a watch to browse its music library",
                systemImage: "applewatch",
                chips: garminChips
            ) {
                Button {
                    ensureLibraryLoaded(force: true)
                } label: {
                    if model.deviceBrowser.isRefreshing || model.isBrowsingDevice {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.deviceBrowser.isRefreshing || model.isBrowsingDevice || model.isManagingDeviceFiles)
            }
            Divider()
            if !model.destinationIsReady && model.connectedUSBDevices.isEmpty {
                garminDisconnected
            } else {
                DeviceContentsView(showsPanelHeader: false, enablesOutboundDrag: true)
            }
        }
        .background(AppTheme.panelBackground(for: .garmin).opacity(0.35))
    }

    private var garminDisconnected: some View {
        VStack(spacing: 12) {
            Image(systemName: "applewatch.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No watch connected")
                .font(.headline)
            Text("Plug in your Garmin, then refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Refresh") {
                model.refreshDevices()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var garminChips: [String] {
        guard model.deviceBrowser.isConfigured else { return [] }
        var chips = ["\(model.deviceBrowser.displayedFiles.count) shown"]
        if !model.deviceBrowser.selectedFileIDs.isEmpty {
            chips.append("\(model.deviceBrowser.selectedFileIDs.count) selected")
        }
        return chips
    }

    // MARK: - Mac pane

    private var macPane: some View {
        FileManagerMacPane(
            macMode: $macMode,
            folderBrowser: folderBrowser,
            onAppleMusicQuickOpen: {
                macMode = .appleMusic
                ensureAppleMusicLoaded()
            }
        )
    }

    // MARK: - Persistence / load

    private func restorePersistedMacState() {
        let settings = model.librarySettings
        if let mode = FileManagerMacMode(rawValue: settings.fileManagerMacMode) {
            macMode = mode
        }
        if let path = settings.fileManagerLastFolderPath {
            let url = URL(fileURLWithPath: path)
            if folderBrowser.currentFolder.standardizedFileURL != url.standardizedFileURL {
                folderBrowser.navigate(to: url)
            }
        }
        if macMode == .appleMusic {
            ensureAppleMusicLoaded()
        }
    }

    private func persistMacMode(_ mode: FileManagerMacMode) {
        var lib = model.librarySettings
        lib.fileManagerMacMode = mode.rawValue
        model.librarySettings = lib
    }

    private func persistFolder(_ folder: URL) {
        var lib = model.librarySettings
        lib.fileManagerLastFolderPath = folder.path
        model.librarySettings = lib
    }

    private func ensureAppleMusicLoaded() {
        switch model.musicLibraryStatus {
        case .loaded:
            break
        case .loading:
            break
        default:
            model.loadAppleMusicLibrary()
        }
    }

    private func ensureLibraryLoaded(force: Bool = false) {
        model.refreshDevices()
        guard model.destinationIsReady || model.canAttemptMTP else { return }
        if force || !model.deviceBrowser.hasFreshListing {
            if model.canAttemptMTP || model.deviceBrowser.backendKind == .mtp {
                model.browseGarminMusicLibrary(force: force || !model.deviceBrowser.hasFreshListing)
            } else {
                model.refreshDeviceContents()
            }
        }
    }
}
