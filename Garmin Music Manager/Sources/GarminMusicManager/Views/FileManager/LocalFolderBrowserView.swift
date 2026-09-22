import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style Mac folder browser used in File Manager.
struct LocalFolderBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: LocalFolderBrowserStore
    var showsPlacesSidebar: Bool = true
    @StateObject private var hoverOpen = FolderHoverOpenController()
    @State private var isDropTarget = false
    @State private var proposedOverlay = "Drop here"

    private var session: DragDropSession { model.dragDropSession }
    private var fm: FileManagerController { model.fileManagerController }

    var body: some View {
        HStack(spacing: 0) {
            if showsPlacesSidebar {
                placesSidebar
                    .frame(width: 148)
                Divider()
            }
            VStack(spacing: 0) {
                tabBar
                toolbar
                Divider()
                if let error = store.lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(8)
                    Divider()
                }
                content
            }
        }
        .dropTargetChrome(
            isTargeted: isDropTarget || (session.highlightDropZone && session.pendingRailHighlightMode == .fileManager),
            isEnabled: canAcceptDrop,
            tint: AppTheme.macTint,
            overlayLabel: proposedOverlay,
            accessibilityLabel: "Mac folder drop target"
        )
        .onDrop(
            of: UnifiedDragPayload.dropTypeIdentifiers,
            isTargeted: canAcceptDrop ? $isDropTarget : .constant(false)
        ) { providers in
            handleDrop(providers, destinationFolder: store.currentFolder)
        }
        .onChange(of: isDropTarget) { _, targeted in
            if targeted {
                proposedOverlay = "Download / copy here"
                session.highlightDropZone = true
            } else if session.pendingRailHighlightMode != .fileManager {
                session.clearDropZoneHighlight()
                hoverOpen.cancel()
            }
        }
        .onAppear {
            store.applySettings(model.librarySettings)
            if session.consumeRailHighlight(for: .fileManager) {
                session.highlightDropZone = true
                proposedOverlay = "Drop into \(store.currentFolder.lastPathComponent)"
            }
        }
        .onChange(of: store.currentFolder) { _, folder in
            fm.macTabs.open(folder, inNewTab: false)
            persistBrowserSettings()
        }
        .onChange(of: store.favoritePaths) { _, paths in
            var lib = model.librarySettings
            lib.fileManagerFavoritePaths = paths
            model.librarySettings = lib
        }
        .onChange(of: store.showHiddenFiles) { _, value in
            var lib = model.librarySettings
            lib.fileManagerShowHiddenFiles = value
            model.librarySettings = lib
            store.refresh()
        }
        .onChange(of: store.recursiveSearch) { _, value in
            var lib = model.librarySettings
            lib.fileManagerRecursiveSearch = value
            model.librarySettings = lib
        }
        .onChange(of: store.viewMode) { _, value in
            var lib = model.librarySettings
            lib.fileManagerViewMode = value.rawValue
            model.librarySettings = lib
        }
        .sheet(isPresented: Binding(
            get: { fm.showNewFolderSheet && fm.focusedPane == .mac },
            set: { fm.showNewFolderSheet = $0 }
        )) {
            newFolderSheet
        }
        .sheet(isPresented: Binding(
            get: { fm.showRenameSheet && fm.focusedPane == .mac },
            set: { fm.showRenameSheet = $0 }
        )) {
            renameSheet
        }
        .sheet(isPresented: Binding(
            get: { fm.showProperties && fm.focusedPane == .mac },
            set: { fm.showProperties = $0 }
        )) {
            if let item = fm.propertiesItem {
                FilePropertiesSheet(item: item)
            }
        }
        .focusable()
        .onTapGesture { fm.focusedPane = .mac }
    }

    private var canAcceptDrop: Bool {
        !model.isManagingDeviceFiles && !store.isRefreshing && !model.isSyncing
    }

    private var placesSidebar: some View {
        List {
            Section("Places") {
                ForEach(store.standardPlaces) { place in
                    Button {
                        store.navigate(to: place.url)
                    } label: {
                        Label(place.title, systemImage: place.systemImage)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(fm.macTabs.tabs) { tab in
                HStack(spacing: 4) {
                    Button(tab.title) {
                        fm.macTabs.select(tab.id)
                        store.navigate(to: URL(fileURLWithPath: tab.path))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(fm.macTabs.selectedTabID == tab.id ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    if fm.macTabs.tabs.count > 1 {
                        Button {
                            fm.macTabs.close(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button {
                fm.macTabs.open(store.currentFolder, inNewTab: true)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Open current folder in new tab")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.panelBackground(for: .mac).opacity(0.35))
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { store.navigateUp() } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .disabled(!store.canNavigateUp)

                breadcrumbBar

                TextField("Path", text: $store.pathDraft, onCommit: { store.navigateToPathDraft() })
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 220)

                Button { store.chooseFolder() } label: {
                    Label("Choose…", systemImage: "folder")
                }

                Spacer(minLength: 8)

                Picker("Sort", selection: $store.sort) {
                    ForEach(LocalFileSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .frame(width: 100)

                Picker("View", selection: $store.viewMode) {
                    Image(systemName: "list.bullet").tag(LocalViewMode.list)
                    Image(systemName: "square.grid.2x2").tag(LocalViewMode.icons)
                }
                .pickerStyle(.segmented)
                .frame(width: 70)

                Button { store.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(store.recursiveSearch ? "Search recursively" : "Search this folder", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Recursive", isOn: $store.recursiveSearch)
                    .toggleStyle(.checkbox)
                    .help("Search subfolders")
                Toggle("Hidden", isOn: $store.showHiddenFiles)
                    .toggleStyle(.checkbox)
                Button {
                    store.toggleFavoriteCurrentFolder()
                } label: {
                    Image(systemName: store.isFavorite(store.currentFolder) ? "star.fill" : "star")
                }
                .help("Favorite this folder")
            }
        }
        .padding(8)
        .background(AppTheme.panelBackground(for: .mac).opacity(0.5))
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(breadcrumbSegments, id: \.path) { segment in
                    Button(segment.name) {
                        store.navigate(to: URL(fileURLWithPath: segment.path))
                    }
                    .buttonStyle(.borderless)
                    .onDrop(of: UnifiedDragPayload.dropTypeIdentifiers, isTargeted: nil) { providers in
                        handleDrop(providers, destinationFolder: URL(fileURLWithPath: segment.path))
                    }
                    if segment.path != store.currentFolder.path {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: 200)
    }

    private var breadcrumbSegments: [(name: String, path: String)] {
        var segments: [(String, String)] = []
        var url = store.currentFolder.standardizedFileURL
        while url.path != "/" {
            segments.insert((url.lastPathComponent, url.path), at: 0)
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
            if segments.count > 6 { break }
        }
        return segments
    }

    @ViewBuilder
    private var content: some View {
        let entries = store.displayedEntries
        if entries.isEmpty {
            Text(store.searchText.isEmpty ? "This folder is empty." : "No items match the search.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu { backgroundContextMenu }
        } else if store.viewMode == .icons {
            iconGrid(entries)
        } else {
            listTable(entries)
        }
    }

    private func listTable(_ entries: [LocalFolderEntry]) -> some View {
        Table(entries, selection: $store.selectedIDs) {
            TableColumn("Name") { entry in
                Label(entry.name, systemImage: entry.systemImage)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .opacity(hoverOpen.pendingFolderID == entry.id ? 0.7 + 0.3 * hoverOpen.progress : 1)
                    .onTapGesture(count: 2) { store.open(entry) }
                    .onDrag { dragProvider(for: entry) }
                    .onDrop(of: UnifiedDragPayload.dropTypeIdentifiers, isTargeted: nil) { providers in
                        handleDrop(providers, destinationFolder: entry.isDirectory ? entry.url : store.currentFolder)
                    }
                    .onContinuousHover { phase in
                        guard entry.isDirectory, session.isDragging || isDropTarget else {
                            hoverOpen.pointerExited(folderID: entry.id)
                            return
                        }
                        switch phase {
                        case .active:
                            hoverOpen.pointerEntered(folderID: entry.id) { store.navigate(to: entry.url) }
                        case .ended:
                            hoverOpen.pointerExited(folderID: entry.id)
                        }
                    }
                    .contextMenu { entryContextMenu(for: entry) }
            }
            TableColumn("Date Modified") { entry in
                Text(entry.modifiedDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
                    .contextMenu { entryContextMenu(for: entry) }
            }
            .width(min: 110, ideal: 130)
            TableColumn("Size") { entry in
                Text(entry.isDirectory
                    ? "—"
                    : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .contextMenu { entryContextMenu(for: entry) }
            }
            TableColumn("Kind") { entry in
                Text(kindLabel(for: entry))
                    .foregroundStyle(.secondary)
                    .contextMenu { entryContextMenu(for: entry) }
            }
        }
        .contextMenu { backgroundContextMenu }
    }

    private func iconGrid(_ entries: [LocalFolderEntry]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 12) {
                ForEach(entries) { entry in
                    VStack(spacing: 6) {
                        Image(systemName: entry.systemImage)
                            .font(.system(size: 28))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                        Text(entry.name)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 88, height: 88)
                    .padding(6)
                    .background(store.selectedIDs.contains(entry.id) ? Color.accentColor.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedIDs = [entry.id] }
                    .onTapGesture(count: 2) { store.open(entry) }
                    .onDrag { dragProvider(for: entry) }
                    .contextMenu { entryContextMenu(for: entry) }
                }
            }
            .padding(12)
        }
        .contextMenu { backgroundContextMenu }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func kindLabel(for entry: LocalFolderEntry) -> String {
        switch entry.kind {
        case .folder: return "Folder"
        case .audio: return "Audio"
        case .playlist: return "Playlist"
        case .other: return "File"
        }
    }

    private func prepareSelection(for entry: LocalFolderEntry) {
        if !store.selectedIDs.contains(entry.id) {
            store.selectedIDs = [entry.id]
        }
        fm.focusedPane = .mac
    }

    private func dragProvider(for entry: LocalFolderEntry) -> NSItemProvider {
        prepareSelection(for: entry)
        let selected = store.selectedEntries
        let urls = selected.map(\.url)
        let bytes = selected.reduce(Int64(0)) { $0 + $1.size }
        let items = DragItemSet(
            localURLs: urls,
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: bytes,
            displayNames: selected.map(\.name)
        )
        session.beginDrag(items)
        return UnifiedDragPayload.itemProvider(for: items)
    }

    @ViewBuilder
    private func entryContextMenu(for entry: LocalFolderEntry) -> some View {
        Button { store.open(entry) } label: {
            Label(entry.isDirectory ? "Open" : "Quick Look", systemImage: "arrow.forward")
        }
        Button { store.revealInFinder(entry) } label: {
            Label("Reveal in Finder", systemImage: "eye")
        }
        Divider()
        Button {
            prepareSelection(for: entry)
            fm.beginNewFolder()
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Button {
            prepareSelection(for: entry)
            fm.beginRename(id: entry.id, currentName: entry.name)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button {
            prepareSelection(for: entry)
            fm.pushUndo(store.trashSelected())
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
        Button {
            prepareSelection(for: entry)
            _ = store.duplicateSelected()
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Button {
            prepareSelection(for: entry)
            model.fileManagerCopySelection(
                from: .mac,
                localURLs: store.selectedEntries.map(\.url),
                names: store.selectedEntries.map(\.name),
                deviceIDs: []
            )
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            prepareSelection(for: entry)
            model.fileManagerCutSelection(
                from: .mac,
                localURLs: store.selectedEntries.map(\.url),
                names: store.selectedEntries.map(\.name),
                deviceIDs: []
            )
        } label: {
            Label("Cut", systemImage: "scissors")
        }
        Button {
            model.fileManagerPaste(into: .mac, localFolder: store.currentFolder)
            store.refresh()
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(fm.clipboard.isEmpty)
        Divider()
        Button {
            prepareSelection(for: entry)
            fm.presentProperties(FilePropertiesModel.local(entry))
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }
        Button {
            prepareSelection(for: entry)
            QuickLookPresenter.preview(urls: store.selectedEntries.map(\.url))
        } label: {
            Label("Quick Look", systemImage: "eye")
        }
        Button {
            prepareSelection(for: entry)
            _ = store.compressSelected()
        } label: {
            Label("Compress", systemImage: "doc.zipper")
        }
        if entry.url.pathExtension.lowercased() == "zip" {
            Button {
                prepareSelection(for: entry)
                _ = store.decompressSelected()
            } label: {
                Label("Decompress", systemImage: "archivebox")
            }
        }
        Divider()
        Button {
            prepareSelection(for: entry)
            model.handleUnifiedDrop(
                items: currentSelectionItems(),
                destination: .deviceMusicRoot,
                destinationLabel: "Garmin music library",
                sourceLabel: store.currentFolder.path
            )
        } label: {
            Label("Copy to Garmin", systemImage: "square.and.arrow.up")
        }
        .disabled(!model.deviceBrowser.isConfigured || model.isManagingDeviceFiles || store.selectedAudioURLs.isEmpty)
        Button("Select All") { store.selectAllDisplayed() }
        Button("Deselect") { store.deselectAll() }
        Button { store.refresh() } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private var backgroundContextMenu: some View {
        Button {
            fm.focusedPane = .mac
            fm.beginNewFolder()
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Button {
            model.fileManagerPaste(into: .mac, localFolder: store.currentFolder)
            store.refresh()
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(fm.clipboard.isEmpty)
        Divider()
        Button { store.chooseFolder() } label: {
            Label("Choose Folder…", systemImage: "folder")
        }
        Button { store.jumpToMusicFolder() } label: {
            Label("Go to Music", systemImage: "music.note")
        }
        Button { store.refresh() } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        let garminSelection = model.deviceBrowser.selectedFiles.filter { $0.type != .folder }
        if !garminSelection.isEmpty {
            Divider()
            Button {
                let items = DragItemSet(
                    localURLs: [],
                    deviceFileIDs: garminSelection.map(\.id),
                    sourceKind: .device,
                    totalByteCount: garminSelection.reduce(0) { $0 + $1.size },
                    displayNames: garminSelection.map(\.name)
                )
                model.handleUnifiedDrop(
                    items: items,
                    destination: .localFolder(store.currentFolder),
                    destinationLabel: store.currentFolder.path,
                    sourceLabel: "Garmin"
                )
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    store.refresh()
                }
            } label: {
                Label("Copy Selected Garmin Files Here", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isManagingDeviceFiles || !model.deviceBrowser.isConfigured)
        }
        Divider()
        Button("Select All") { store.selectAllDisplayed() }
        Button("Deselect") { store.deselectAll() }
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder").font(.headline)
            TextField("Name", text: Binding(
                get: { fm.newFolderName },
                set: { fm.newFolderName = $0 }
            ))
            HStack {
                Spacer()
                Button("Cancel") { fm.showNewFolderSheet = false }
                Button("Create") {
                    _ = store.createFolder(named: fm.newFolderName)
                    fm.showNewFolderSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename").font(.headline)
            TextField("Name", text: Binding(
                get: { fm.renameDraft },
                set: { fm.renameDraft = $0 }
            ))
            HStack {
                Spacer()
                Button("Cancel") { fm.showRenameSheet = false }
                Button("Rename") {
                    fm.pushUndo(store.renameSelected(to: fm.renameDraft))
                    fm.showRenameSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func persistBrowserSettings() {
        var lib = model.librarySettings
        lib.fileManagerMacTabPaths = fm.macTabs.tabs.map(\.path)
        model.librarySettings = lib
    }

    private func currentSelectionItems() -> DragItemSet {
        let selected = store.selectedEntries
        return DragItemSet(
            localURLs: selected.map(\.url),
            deviceFileIDs: [],
            sourceKind: .localFolder,
            totalByteCount: selected.reduce(0) { $0 + $1.size },
            displayNames: selected.map(\.name)
        )
    }

    @discardableResult
    private func handleDrop(_ providers: [NSItemProvider], destinationFolder: URL) -> Bool {
        UnifiedDragPayload.load(from: providers) { items in
            defer { session.endDrag() }
            guard !items.isEmpty else { return }
            proposedOverlay = model.dragCoordinator.propose(
                items: items,
                destination: .localFolder(destinationFolder)
            ).dropOverlayLabel(for: .localFolder(destinationFolder))
            model.handleUnifiedDrop(
                items: items,
                destination: .localFolder(destinationFolder),
                destinationLabel: destinationFolder.path,
                sourceLabel: items.sourceKind == .device ? "Garmin" : "Mac"
            )
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                store.refresh()
            }
        }
        return true
    }
}

struct FilePropertiesSheet: View {
    let item: FilePropertiesModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Info").font(.title2.bold())
            LabeledContent("Name", value: item.name)
            LabeledContent("Kind", value: item.kind)
            LabeledContent("Size", value: item.sizeLabel)
            LabeledContent("Path", value: item.path)
            if let modified = item.modified {
                LabeledContent("Modified", value: modified.formatted())
            }
            ForEach(item.extra.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                LabeledContent(key, value: value)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
