import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dual-pane File Manager: Garmin library (left) and Mac folders / Apple Music (right).
struct FileManagerView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var folderBrowser = LocalFolderBrowserStore()
    @State private var macMode: FileManagerMacMode = .folders
    @State private var didRestorePersistedState = false

    private var fm: FileManagerController { model.fileManagerController }

    var body: some View {
        VStack(spacing: 0) {
            syncToolbar
            if let banner = fm.lastEmulationBanner {
                emulationBanner(banner)
            }
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
        .confirmationDialog(
            syncConfirmTitle,
            isPresented: Binding(
                get: { fm.showSyncConfirm },
                set: { fm.showSyncConfirm = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Run Sync") {
                model.executePendingSyncPlan(macFolder: folderBrowser.currentFolder)
                folderBrowser.refresh()
            }
            Button("Cancel", role: .cancel) {
                model.cancelPendingSyncPlan()
            }
        } message: {
            Text(syncConfirmMessage)
        }
        .sheet(isPresented: Binding(
            get: { fm.showMirrorConfirm },
            set: { if !$0 { model.cancelPendingSyncPlan() } else { fm.showMirrorConfirm = $0 } }
        )) {
            mirrorConfirmSheet
        }
    }

    private var syncToolbar: some View {
        HStack(spacing: 8) {
            Text("Dual-pane")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button("Compare") { comparePanes() }
            Button("Copy →") { planSync(.copyLeftToRight) }
            Button("Copy ←") { planSync(.copyRightToLeft) }
            Button("Sync newer →") { planSync(.syncNewerLeftToRight) }
            Button("Sync newer ←") { planSync(.syncNewerRightToLeft) }
            Button("Mirror →", role: .destructive) { planSync(.mirrorLeftToRight) }
            Button("Mirror ←", role: .destructive) { planSync(.mirrorRightToLeft) }
            Spacer()
            if let summary = fm.compareSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !fm.clipboard.isEmpty {
                Text(fm.clipboard.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func emulationBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { fm.clearEmulationBanner() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var syncConfirmTitle: String {
        guard let plan = fm.pendingSyncPlan else { return "Confirm sync" }
        return "\(plan.action.title): \(plan.copyCount) copy, \(plan.deleteCount) delete"
    }

    private var syncConfirmMessage: String {
        guard let plan = fm.pendingSyncPlan else { return "" }
        let bytes = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
        return "About \(bytes) will transfer. Overwrite policy from Settings still applies."
    }

    private var mirrorConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mirror can delete files")
                .font(.headline)
            Text("This will copy missing/different items and delete extras on the destination that are not on the source.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let plan = fm.pendingSyncPlan {
                Text("\(plan.copyCount) to copy, \(plan.deleteCount) to delete.")
                    .font(.caption)
            }
            Toggle("I understand this can permanently delete files", isOn: Binding(
                get: { fm.mirrorAcknowledged },
                set: { fm.mirrorAcknowledged = $0 }
            ))
            HStack {
                Spacer()
                Button("Cancel") { model.cancelPendingSyncPlan() }
                Button("Mirror", role: .destructive) {
                    model.executePendingSyncPlan(macFolder: folderBrowser.currentFolder)
                    folderBrowser.refresh()
                }
                .disabled(!fm.mirrorAcknowledged)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Sync planning

    private func comparePanes() {
        let left = garminListing()
        let right = macListing()
        let onlyLeft = Set(left.map { $0.name.lowercased() }).subtracting(right.map { $0.name.lowercased() })
        let onlyRight = Set(right.map { $0.name.lowercased() }).subtracting(left.map { $0.name.lowercased() })
        fm.compareSummary = "Garmin-only \(onlyLeft.count) · Mac-only \(onlyRight.count) · Shared \(left.count + right.count - onlyLeft.count - onlyRight.count)"
    }

    private func planSync(_ action: DualPaneSyncAction) {
        let plan = DualPaneSyncPlanner.plan(action: action, left: garminListing(), right: macListing())
        if plan.items.isEmpty {
            fm.compareSummary = "Nothing to do for \(action.title)"
            return
        }
        fm.presentSyncPlan(plan)
    }

    private func garminListing() -> [SyncListingItem] {
        model.deviceBrowser.displayedFiles.map { file in
            SyncListingItem(
                name: file.name,
                size: file.size,
                modified: file.modifiedDate,
                isDirectory: file.type == .folder,
                localURL: nil,
                deviceFileID: file.id
            )
        }
    }

    private func macListing() -> [SyncListingItem] {
        folderBrowser.entries.map { entry in
            SyncListingItem(
                name: entry.name,
                size: entry.size,
                modified: entry.modifiedDate,
                isDirectory: entry.isDirectory,
                localURL: entry.url,
                deviceFileID: nil
            )
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
        .onTapGesture { fm.focusedPane = .garmin }
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
        .onTapGesture { fm.focusedPane = .mac }
    }

    // MARK: - Persistence / load

    private func restorePersistedMacState() {
        let settings = model.librarySettings
        if let mode = FileManagerMacMode(rawValue: settings.fileManagerMacMode) {
            macMode = mode
        }
        folderBrowser.applySettings(settings)
        if let path = settings.fileManagerLastFolderPath {
            let url = URL(fileURLWithPath: path)
            if folderBrowser.currentFolder.standardizedFileURL != url.standardizedFileURL {
                folderBrowser.navigate(to: url)
            }
        }
        if !settings.fileManagerMacTabPaths.isEmpty {
            for (index, path) in settings.fileManagerMacTabPaths.enumerated() {
                fm.macTabs.open(URL(fileURLWithPath: path), inNewTab: index > 0)
            }
        } else {
            fm.macTabs.open(folderBrowser.currentFolder, inNewTab: false)
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
        lib.fileManagerMacTabPaths = fm.macTabs.tabs.map(\.path)
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
