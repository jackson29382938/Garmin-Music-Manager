import AppKit
import GarminMusicCore
import SwiftUI
import UniformTypeIdentifiers

struct DeviceContentsView: View {
    @EnvironmentObject private var model: AppModel
    /// When embedded under On Watch, the parent already provides title/refresh.
    var showsPanelHeader: Bool = true
    /// When true (File Manager / On Watch), selected files can be dragged to the Mac pane or Finder.
    var enablesOutboundDrag: Bool = false
    @State private var isUploadDropTarget = false
    @State private var availableWidth: CGFloat = 0
    @State private var dropOverlayLabel = "Drop to add to Garmin"
    @StateObject private var hoverOpen = FolderHoverOpenController()

    private var browser: DeviceBrowserStore {
        model.deviceBrowser
    }

    private var session: DragDropSession { model.dragDropSession }

    private var usesCompactLayout: Bool {
        availableWidth > 0 && availableWidth < 820
    }

    var body: some View {
        VStack(spacing: 0) {
            DeviceContentsToolbar(
                showsPanelHeader: showsPanelHeader,
                usesCompactLayout: usesCompactLayout,
                summaryText: summaryText,
                chips: garminHeaderChips,
                onRefresh: refreshDeviceLibrary
            )
            Divider()

            if let operation = browser.operation {
                DeviceOperationBanner(operation: operation) {
                    model.cancelDeviceOperation()
                }
                Divider()
            } else if let error = browser.lastError {
                DeviceStatusBanner(message: error, systemImage: "exclamationmark.triangle", tint: .orange)
                Divider()
            } else if browser.browseMode == .advancedStorage {
                DeviceStatusBanner(
                    message: "Advanced storage is visible. Destructive changes outside music folders always require confirmation.",
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                )
                Divider()
            }

            if !browser.isConfigured {
                emptyState(
                    title: "Connect your Garmin",
                    message: browser.statusMessage
                        ?? "Connect via USB and click Refresh above, or choose a music folder in Transfer or Settings."
                )
            } else if browser.isRefreshing && browser.files.isEmpty {
                loadingState
            } else if browser.files.isEmpty {
                emptyState(
                    title: emptyBrowserTitle,
                    message: browser.statusMessage ?? (browser.backendKind == .mtp
                        ? "Nothing here yet. Prefer Transfer → Send to Watch for playlists and conversion. Add/drop here only puts files on the watch (no playlist)."
                        : "Drop tracks here or use Add (direct copy — no playlist). Prefer Transfer for full Send to Watch.")
                )
            } else {
                browserContent
            }
        }
        .frame(minHeight: 130, idealHeight: 340, maxHeight: .infinity)
        .background(AppTheme.panelBackground(for: .garmin).opacity(isUploadDropTarget ? 1 : 0.5))
        .background(WidthReader(width: $availableWidth))
        .overlay {
            ZStack {
                if isUploadDropTarget || (session.highlightDropZone && session.pendingRailHighlightMode == .onWatch) {
                    Text(dropOverlayLabel)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.garminTint)
                }
                RoundedRectangle(cornerRadius: AppTheme.panelCornerRadius, style: .continuous)
                    .strokeBorder(
                        (isUploadDropTarget || session.highlightDropZone) ? AppTheme.garminTint : Color.clear,
                        lineWidth: 2
                    )
                    .padding(4)
            }
        }
        .onDrop(
            of: UnifiedDragPayload.dropTypeIdentifiers,
            isTargeted: canAcceptUploadDrop ? $isUploadDropTarget : .constant(false)
        ) { providers in
            handleUnifiedUploadDrop(providers)
        }
        .onChange(of: isUploadDropTarget) { _, targeted in
            if targeted {
                dropOverlayLabel = "Copy to Garmin"
                session.highlightDropZone = true
            } else if session.pendingRailHighlightMode != .onWatch {
                session.clearDropZoneHighlight()
            }
        }
        .onAppear {
            if session.consumeRailHighlight(for: .onWatch) {
                session.highlightDropZone = true
                dropOverlayLabel = "Drop to copy to Garmin"
            }
        }
        .contextMenu {
            if browser.isConfigured {
                deviceBackgroundContextMenu
            }
        }
        .sheet(isPresented: Binding(
            get: { model.fileManagerController.showNewFolderSheet && model.fileManagerController.focusedPane == .garmin },
            set: { model.fileManagerController.showNewFolderSheet = $0 }
        )) {
            deviceNewFolderSheet
        }
        .sheet(isPresented: Binding(
            get: { model.fileManagerController.showRenameSheet && model.fileManagerController.focusedPane == .garmin },
            set: { model.fileManagerController.showRenameSheet = $0 }
        )) {
            deviceRenameSheet
        }
        .sheet(isPresented: Binding(
            get: { model.fileManagerController.showProperties && model.fileManagerController.focusedPane == .garmin },
            set: { model.fileManagerController.showProperties = $0 }
        )) {
            if let item = model.fileManagerController.propertiesItem {
                FilePropertiesSheet(item: item)
            }
        }
    }

    private var deviceNewFolderSheet: some View {
        let fm = model.fileManagerController
        return VStack(alignment: .leading, spacing: 12) {
            Text("New Folder on Watch").font(.headline)
            Text("Uses MTP folder creation (may be slow).")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: Binding(
                get: { fm.newFolderName },
                set: { fm.newFolderName = $0 }
            ))
            HStack {
                Spacer()
                Button("Cancel") { fm.showNewFolderSheet = false }
                Button("Create") {
                    model.createDeviceFolder(named: fm.newFolderName)
                    fm.showNewFolderSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var deviceRenameSheet: some View {
        let fm = model.fileManagerController
        return VStack(alignment: .leading, spacing: 12) {
            Text("Rename on Watch").font(.headline)
            Text("Emulated MTP rename downloads, re-uploads, then deletes the original.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: Binding(
                get: { fm.renameDraft },
                set: { fm.renameDraft = $0 }
            ))
            HStack {
                Spacer()
                Button("Cancel") { fm.showRenameSheet = false }
                Button("Rename") {
                    model.renameSelectedDeviceFile(to: fm.renameDraft)
                    fm.showRenameSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var canAcceptUploadDrop: Bool {
        browser.isConfigured
            && !model.isManagingDeviceFiles
            && !browser.isRefreshing
            && browser.browseMode != .advancedStorage
    }

    private var emptyBrowserTitle: String {
        if browser.browseMode == .advancedStorage {
            return "No files found"
        }
        if browser.backendKind == .mtp {
            return "No manageable music files found"
        }
        return "No music files found"
    }

    @ViewBuilder
    private var browserContent: some View {
        if usesCompactLayout {
            fileTable
        } else {
            HStack(spacing: 0) {
                collectionSidebar
                Divider()
                fileTable
            }
        }
    }

    private var garminHeaderChips: [String] {
        guard browser.isConfigured else { return [] }
        var chips = ["\(browser.displayedFiles.count) shown"]
        if !browser.selectedFileIDs.isEmpty {
            chips.append("\(browser.selectedFileIDs.count) selected")
        }
        return chips
    }

    private func refreshDeviceLibrary() {
        if browser.backendKind == .mtp || model.canAttemptMTP {
            model.browseGarminMusicLibrary()
        } else if model.activeDestination == nil {
            model.refreshDevices()
        } else {
            model.refreshDeviceContents()
        }
    }

    private var collectionSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collections")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            List(selection: $model.deviceBrowser.selectedCollectionID) {
                ForEach(browser.collections) { collection in
                    DeviceCollectionRow(collection: collection)
                        .tag(collection.id)
                        .onContinuousHover { phase in
                            guard collection.kind == .folder || collection.kind == .playlist,
                                  session.isDragging || isUploadDropTarget else {
                                hoverOpen.pointerExited(folderID: collection.id)
                                return
                            }
                            switch phase {
                            case .active:
                                hoverOpen.pointerEntered(folderID: collection.id) {
                                    model.deviceBrowser.selectedCollectionID = collection.id
                                }
                            case .ended:
                                hoverOpen.pointerExited(folderID: collection.id)
                            }
                        }
                        .onDrop(of: UnifiedDragPayload.dropTypeIdentifiers, isTargeted: nil) { providers in
                            if collection.kind == .playlist || collection.kind == .folder {
                                return handleDropOntoCollection(providers, collection: collection)
                            }
                            return handleUnifiedUploadDrop(providers)
                        }
                        .contextMenu {
                            Button {
                                model.deviceBrowser.selectedCollectionID = collection.id
                            } label: {
                                Label("Show This Collection", systemImage: "folder")
                            }
                            Button {
                                refreshDeviceLibrary()
                            } label: {
                                Label("Refresh Library", systemImage: "arrow.clockwise")
                            }
                            .disabled(browser.isRefreshing || model.isManagingDeviceFiles)
                        }
                }
            }
            .listStyle(.sidebar)
            .contextMenu {
                Button {
                    model.startCreatePlaylistFromSelection()
                } label: {
                    Label("New Playlist…", systemImage: "music.note.list")
                }
                .disabled(!model.canCreatePlaylistFromSelection)
                Button {
                    refreshDeviceLibrary()
                } label: {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }
                .disabled(browser.isRefreshing || model.isManagingDeviceFiles)
            }
        }
        .frame(width: 220)
    }

    private var fileTable: some View {
        VStack(spacing: 0) {
            fileToolbar

            if usesCompactLayout {
                compactFileTable
            } else {
                regularFileTable
            }

            if !browser.unmatchedItemsForSelectedCollection.isEmpty {
                unmatchedRows
            }
        }
    }

    private var fileToolbar: some View {
        Group {
            if usesCompactLayout {
                compactFileToolbar
            } else {
                regularFileToolbar
            }
        }
        .padding(8)
        .background(AppTheme.panelBackground(for: .garmin).opacity(0.35))
    }

    private var regularFileToolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            deviceBreadcrumb
            HStack(spacing: 8) {
                searchField
                sortPicker
                    .frame(width: 160)
                Spacer(minLength: 8)
                shownCount
            }
        }
    }

    private var deviceBreadcrumb: some View {
        HStack(spacing: 4) {
            Image(systemName: "applewatch")
                .foregroundStyle(.secondary)
            Text(browser.selectedCollection?.name ?? (browser.browseMode == .advancedStorage ? "Storage" : "Music"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let file = browser.selectedFiles.first {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(file.path.isEmpty ? file.name : file.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private static let deviceDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var compactFileToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            collectionPicker

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    searchField
                    sortPicker
                        .frame(width: 140)
                    Spacer(minLength: 8)
                    shownCount
                }

                VStack(alignment: .leading, spacing: 8) {
                    searchField
                    HStack(spacing: 8) {
                        sortPicker
                        Spacer(minLength: 8)
                        shownCount
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Garmin library", text: $model.deviceBrowser.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: .infinity)
        }
    }

    private var collectionPicker: some View {
        Picker("Collection", selection: $model.deviceBrowser.selectedCollectionID) {
            ForEach(browser.collections) { collection in
                Text(collection.name).tag(collection.id)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $model.deviceBrowser.sortOrder) {
            ForEach(DeviceFileSort.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.menu)
    }

    private var shownCount: some View {
        Text("\(browser.displayedFiles.count) shown")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var regularFileTable: some View {
        Table(browser.displayedFiles, selection: $model.deviceBrowser.selectedFileIDs) {
            TableColumn("Name") { file in
                fileNameLabel(for: file)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        fileContextMenu(for: file)
                    }
            }

            TableColumn("Artist / Album") { file in
                Text(metadataText(for: file))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu { fileContextMenu(for: file) }
            }

            TableColumn("Location") { file in
                Text(file.locationDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu { fileContextMenu(for: file) }
            }

            TableColumn("Size") { file in
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contextMenu { fileContextMenu(for: file) }
            }

            TableColumn("Date") { file in
                Text(file.modifiedDate.map { Self.deviceDateFormatter.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contextMenu { fileContextMenu(for: file) }
            }
            .width(min: 100, ideal: 120)

            TableColumn("Type") { file in
                Text(typeText(for: file))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contextMenu { fileContextMenu(for: file) }
            }
        }
        .contextMenu {
            deviceBackgroundContextMenu
        }
    }

    private var compactFileTable: some View {
        Table(browser.displayedFiles, selection: $model.deviceBrowser.selectedFileIDs) {
            TableColumn("Name") { file in
                VStack(alignment: .leading, spacing: 2) {
                    fileNameLabel(for: file)

                    Text(metadataText(for: file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(file.locationDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    fileContextMenu(for: file)
                }
            }

            TableColumn("Info") { file in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    Text(typeText(for: file))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contextMenu { fileContextMenu(for: file) }
            }
        }
        .contextMenu {
            deviceBackgroundContextMenu
        }
    }

    private func fileNameLabel(for file: DeviceFile) -> some View {
        Label(file.name, systemImage: systemImage(for: file))
            .lineLimit(1)
            .truncationMode(.middle)
            .modifier(DeviceFileDragModifier(
                enabled: enablesOutboundDrag && file.type != .folder,
                file: file,
                selectedIDs: model.deviceBrowser.selectedFileIDs,
                selectedFiles: browser.displayedFiles,
                onBeginDrag: { items in
                    model.dragDropSession.beginDrag(items)
                }
            ))
    }

    /// Finder-style: right-click outside the selection selects only that file;
    /// right-click inside the selection keeps multi-select for the action.
    private func prepareDeviceSelection(for file: DeviceFile) {
        if !model.deviceBrowser.selectedFileIDs.contains(file.id) {
            model.deviceBrowser.selectedFileIDs = [file.id]
        }
    }

    @ViewBuilder
    private func fileContextMenu(for file: DeviceFile) -> some View {
        Button {
            prepareDeviceSelection(for: file)
            model.copySelectedDeviceFilesToMac()
        } label: {
            Label("Copy to Mac", systemImage: "square.and.arrow.down")
        }
        .disabled(model.isManagingDeviceFiles)

        Button {
            prepareDeviceSelection(for: file)
            model.startMoveSelectedWithinGarmin()
        } label: {
            Label("Move Within Garmin", systemImage: "music.note.list")
        }
        .disabled(model.isManagingDeviceFiles || file.type == .folder)

        Button {
            prepareDeviceSelection(for: file)
            model.startCreatePlaylistFromSelection()
        } label: {
            Label("New Playlist…", systemImage: "music.note.list")
        }
        .disabled(
            model.isManagingDeviceFiles
                || file.type != .audio
                || model.deviceBrowser.backendKind != .mtp
        )

        Divider()

        Button {
            model.fileManagerController.focusedPane = .garmin
            model.fileManagerController.beginNewFolder()
        } label: {
            Label("New Folder…", systemImage: "folder.badge.plus")
        }
        .disabled(model.isManagingDeviceFiles || !browser.isConfigured)

        Button {
            prepareDeviceSelection(for: file)
            model.fileManagerController.focusedPane = .garmin
            model.fileManagerController.beginRename(id: file.id, currentName: file.name)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        .disabled(model.isManagingDeviceFiles)

        Button(role: .destructive) {
            prepareDeviceSelection(for: file)
            model.requestDeleteSelectedDeviceFiles()
        } label: {
            Label("Delete…", systemImage: "trash")
        }
        .disabled(model.isManagingDeviceFiles)

        Divider()

        Button {
            prepareDeviceSelection(for: file)
            model.fileManagerCopySelection(
                from: .garmin,
                localURLs: [],
                names: browser.selectedFiles.map(\.name),
                deviceIDs: Array(browser.selectedFileIDs)
            )
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            prepareDeviceSelection(for: file)
            model.fileManagerCutSelection(
                from: .garmin,
                localURLs: [],
                names: browser.selectedFiles.map(\.name),
                deviceIDs: Array(browser.selectedFileIDs)
            )
        } label: {
            Label("Cut", systemImage: "scissors")
        }

        Button {
            model.fileManagerPaste(into: .garmin, localFolder: nil)
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(model.fileManagerController.clipboard.isEmpty || model.isManagingDeviceFiles)

        Divider()

        Button {
            prepareDeviceSelection(for: file)
            model.fileManagerController.focusedPane = .garmin
            model.fileManagerController.presentProperties(FilePropertiesModel.device(file))
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }

        Button {
            prepareDeviceSelection(for: file)
            model.quickLookSelectedDeviceFiles()
        } label: {
            Label("Quick Look", systemImage: "eye")
        }
        .disabled(file.type == .folder || model.isManagingDeviceFiles)

        Button {
            prepareDeviceSelection(for: file)
            let folder = LocalFolderBrowserStore.defaultMusicFolder
            model.zipSelectedDeviceFilesToMac(folder: folder)
        } label: {
            Label("Zip to Mac Music…", systemImage: "doc.zipper")
        }
        .disabled(file.type == .folder || model.isManagingDeviceFiles)

        Divider()

        Button("Select All Shown") {
            model.deviceBrowser.selectedFileIDs = Set(browser.displayedFiles.map(\.id))
        }
        .disabled(browser.displayedFiles.isEmpty)

        Button("Deselect") {
            model.deviceBrowser.selectedFileIDs.removeAll()
        }
        .disabled(browser.selectedFileIDs.isEmpty)

        Button {
            refreshDeviceLibrary()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(browser.isRefreshing || model.isManagingDeviceFiles)

        Divider()

        Button {
            copyToPasteboard(file.name)
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }

        Button {
            let path = file.path.isEmpty ? file.name : file.path
            copyToPasteboard(path)
        } label: {
            Label("Copy Path", systemImage: "link")
        }

        Divider()

        Button {
            model.chooseFilesToUploadToDevice()
        } label: {
            Label("Add files (no playlist)…", systemImage: "plus")
        }
        .disabled(!browser.isConfigured || model.isManagingDeviceFiles || browser.browseMode == .advancedStorage)
    }

    @ViewBuilder
    private var deviceBackgroundContextMenu: some View {
        Button {
            model.fileManagerController.focusedPane = .garmin
            model.fileManagerController.beginNewFolder()
        } label: {
            Label("New Folder…", systemImage: "folder.badge.plus")
        }
        .disabled(model.isManagingDeviceFiles || !browser.isConfigured)

        Button {
            model.fileManagerPaste(into: .garmin, localFolder: nil)
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(model.fileManagerController.clipboard.isEmpty || model.isManagingDeviceFiles)

        Divider()

        Button {
            refreshDeviceLibrary()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(browser.isRefreshing || model.isManagingDeviceFiles)

        Button {
            model.chooseFilesToUploadToDevice()
        } label: {
            Label("Add files (no playlist)…", systemImage: "plus")
        }
        .disabled(!browser.isConfigured || model.isManagingDeviceFiles || browser.browseMode == .advancedStorage)

        if !browser.displayedFiles.isEmpty {
            Divider()
            Button("Select All Shown") {
                model.deviceBrowser.selectedFileIDs = Set(browser.displayedFiles.map(\.id))
            }
            Button("Deselect") {
                model.deviceBrowser.selectedFileIDs.removeAll()
            }
            .disabled(browser.selectedFileIDs.isEmpty)
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var unmatchedRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Unmatched playlist items")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(browser.unmatchedItemsForSelectedCollection, id: \.self) { item in
                Label(item, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.25))
    }

    private var loadingState: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 10) {
                ProgressView()
                Text(browser.browseMode == .advancedStorage ? "Reading Garmin storage..." : "Reading Garmin music...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(browser.browseMode == .advancedStorage ? "Reading Garmin storage..." : "Reading Garmin music...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyState(title: String, message: String) -> some View {
        ViewThatFits(in: .vertical) {
            fullEmptyState(title: title, message: message)
            compactEmptyState(title: title, message: message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func fullEmptyState(title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.garminTint.opacity(0.7))
            Text(title)
                .font(.title3.bold())
                .lineLimit(1)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 400)

            emptyStateAction
        }
    }

    private func compactEmptyState(title: String, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: emptyStateIcon)
                .font(.title2)
                .foregroundStyle(AppTheme.garminTint.opacity(0.75))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            emptyStateAction
        }
    }

    @ViewBuilder
    private var emptyStateAction: some View {
        if !browser.isConfigured {
            HStack(spacing: 8) {
                Button("Refresh") {
                    model.refreshDevices()
                }
                .buttonStyle(.bordered)
                if !model.mtpDependencyStatus.isReady, model.mtpDependencyStatus.canInstallViaHomebrew {
                    Button("Install MTP") {
                        model.installMTPDependencies()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInstallingMTPDependencies)
                }
                Button("Choose folder…") {
                    model.chooseCustomGarminFolder()
                }
                .buttonStyle(.bordered)
            }
        } else if browser.files.isEmpty {
            Button("Add files (no playlist)") {
                model.chooseFilesToUploadToDevice()
            }
            .buttonStyle(.bordered)
            .help("Direct upload without playlist, convert, or overwrite policies. Use Transfer → Send to Watch for full send.")
            .disabled(!browser.isConfigured || browser.browseMode == .advancedStorage)
        }
    }

    private var emptyStateIcon: String {
        if !browser.isConfigured { return "cable.connector" }
        if browser.backendKind == .mtp { return "applewatch" }
        return "music.note.list"
    }

    private var summaryText: String {
        guard let storage = browser.storageInfo else {
            return model.garminLibraryLocationDescription
        }
        let bytes = ByteCountFormatter.string(fromByteCount: storage.usedByFiles, countStyle: .file)
        return "\(model.garminLibraryLocationDescription) - \(storage.fileCount) files - \(bytes)"
    }

    private func handleUploadDrop(_ providers: [NSItemProvider]) -> Bool {
        handleUnifiedUploadDrop(providers)
    }

    private func handleUnifiedUploadDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptUploadDrop, !providers.isEmpty else { return false }

        UnifiedDragPayload.load(from: providers) { items in
            defer { model.dragDropSession.endDrag() }
            guard !items.isEmpty else { return }
            if !items.deviceFileIDs.isEmpty {
                model.deviceBrowser.selectedFileIDs = Set(items.deviceFileIDs)
                model.startMoveSelectedWithinGarmin()
                return
            }
            dropOverlayLabel = model.dragCoordinator.propose(
                items: items,
                destination: .deviceMusicRoot
            ).dropOverlayLabel(for: .deviceMusicRoot)
            model.handleUnifiedDrop(
                items: items,
                destination: .deviceMusicRoot,
                destinationLabel: "Garmin music library",
                sourceLabel: "Mac"
            )
        }
        return true
    }

    private func handleDropOntoCollection(_ providers: [NSItemProvider], collection: DeviceCollection) -> Bool {
        guard canAcceptUploadDrop || !providers.isEmpty else { return false }
        UnifiedDragPayload.load(from: providers) { items in
            defer { model.dragDropSession.endDrag() }
            guard !items.isEmpty else { return }
            let destination: DropDestination = (collection.kind == .playlist || collection.kind == .folder)
                ? .devicePlaylistFolder(name: collection.name)
                : .deviceMusicRoot

            // Watch → Watch playlist/folder: move into that playlist.
            if !items.deviceFileIDs.isEmpty {
                model.deviceBrowser.selectedFileIDs = Set(items.deviceFileIDs)
                if collection.kind == .playlist || collection.kind == .folder {
                    model.moveSelectedWithinGarmin(toPlaylist: collection.name)
                } else {
                    model.startMoveSelectedWithinGarmin()
                }
                return
            }

            // Mac → Watch: copy (upload), then associate with playlist when possible.
            dropOverlayLabel = model.dragCoordinator.propose(
                items: items,
                destination: destination
            ).dropOverlayLabel(for: destination)
            model.handleUnifiedDrop(
                items: items,
                destination: destination,
                destinationLabel: collection.name,
                sourceLabel: "Mac"
            )
        }
        return true
    }

    private func metadataText(for file: DeviceFile) -> String {
        let values = [
            file.audioMetadata?.artist,
            file.audioMetadata?.album
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        return values.isEmpty ? "-" : values.joined(separator: " / ")
    }

    private func typeText(for file: DeviceFile) -> String {
        switch file.type {
        case .audio:
            return "Audio"
        case .playlist:
            return "Playlist"
        case .folder:
            return "Folder"
        case .other:
            return "File"
        }
    }

    private func systemImage(for file: DeviceFile) -> String {
        switch file.type {
        case .audio:
            return "music.note"
        case .playlist:
            return "list.bullet.rectangle"
        case .folder:
            return "folder"
        case .other:
            return "doc"
        }
    }
}

/// Applies outbound device-file drag when File Manager / On Watch embeds the Garmin pane.
private struct DeviceFileDragModifier: ViewModifier {
    let enabled: Bool
    let file: DeviceFile
    let selectedIDs: Set<String>
    let selectedFiles: [DeviceFile]
    var onBeginDrag: (DragItemSet) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                let files: [DeviceFile]
                if selectedIDs.contains(file.id) {
                    files = selectedFiles.filter { selectedIDs.contains($0.id) && $0.type != .folder }
                } else {
                    files = file.type == .folder ? [] : [file]
                }
                let items = DragItemSet(
                    localURLs: [],
                    deviceFileIDs: files.map(\.id),
                    sourceKind: .device,
                    totalByteCount: files.reduce(0) { $0 + $1.size },
                    displayNames: files.map(\.name)
                )
                onBeginDrag(items)
                return UnifiedDragPayload.itemProvider(for: items)
            }
        } else {
            content
        }
    }
}


