import GarminMusicCore
import SwiftUI
import UniformTypeIdentifiers

struct DeviceContentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isUploadDropTarget = false
    @State private var availableWidth: CGFloat = 0

    private var browser: DeviceBrowserStore {
        model.deviceBrowser
    }

    private var usesCompactLayout: Bool {
        availableWidth > 0 && availableWidth < 820
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let operation = browser.operation {
                OperationBanner(operation: operation) {
                    model.cancelDeviceOperation()
                }
                Divider()
            } else if let error = browser.lastError {
                StatusBanner(message: error, systemImage: "exclamationmark.triangle", tint: .orange)
                Divider()
            } else if browser.browseMode == .advancedStorage {
                StatusBanner(
                    message: "Advanced storage is visible. Destructive changes outside music folders always require confirmation.",
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                )
                Divider()
            }

            if !browser.isConfigured {
                emptyState(
                    title: "Step 1: Connect your Garmin",
                    message: browser.statusMessage ?? "Connect via USB and click Refresh in the sidebar, or choose a custom folder."
                )
            } else if browser.isRefreshing && browser.files.isEmpty {
                loadingState
            } else if browser.files.isEmpty {
                emptyState(
                    title: browser.browseMode == .advancedStorage ? "No files found" : "No music on watch yet",
                    message: browser.statusMessage ?? (browser.backendKind == .mtp
                        ? "Sync a playlist below, or drop tracks here to add directly."
                        : "Drop tracks here or use Add to Garmin.")
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
                if isUploadDropTarget {
                    Text("Drop to add to Garmin")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.garminTint)
                }
                RoundedRectangle(cornerRadius: AppTheme.panelCornerRadius, style: .continuous)
                    .strokeBorder(
                        isUploadDropTarget ? AppTheme.garminTint : Color.clear,
                        lineWidth: 2
                    )
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isUploadDropTarget) { providers in
            handleUploadDrop(providers)
        }
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

    private var toolbar: some View {
        VStack(spacing: 0) {
            PanelHeader(
                side: .garmin,
                title: "Garmin Library",
                subtitle: summaryText,
                systemImage: "applewatch",
                chips: garminHeaderChips
            ) {
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

    private var deviceActions: some View {
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

    private var refreshButton: some View {
        Button {
            if browser.backendKind == .mtp || model.canAttemptMTP {
                model.browseGarminMusicLibrary()
            } else if model.activeDestination == nil {
                model.refreshDevices()
            } else {
                model.refreshDeviceContents()
            }
        } label: {
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

    private var collectionSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collections")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            List(selection: $model.deviceBrowser.selectedCollectionID) {
                ForEach(browser.collections) { collection in
                    CollectionRow(collection: collection)
                        .tag(collection.id)
                }
            }
            .listStyle(.sidebar)
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
        HStack(spacing: 8) {
            searchField
            sortPicker
                .frame(width: 160)
            Spacer(minLength: 8)
            shownCount
        }
    }

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
                    .contextMenu {
                        fileContextMenu(for: file)
                    }
            }

            TableColumn("Artist / Album") { file in
                Text(metadataText(for: file))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TableColumn("Location") { file in
                Text(file.locationDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TableColumn("Size") { file in
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TableColumn("Type") { file in
                Text(typeText(for: file))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
            }
        }
    }

    private func fileNameLabel(for file: DeviceFile) -> some View {
        Label(file.name, systemImage: systemImage(for: file))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func fileContextMenu(for file: DeviceFile) -> some View {
        Button {
            model.deviceBrowser.selectedFileIDs = [file.id]
            model.copySelectedDeviceFilesToMac()
        } label: {
            Label("Copy to Mac", systemImage: "square.and.arrow.down")
        }

        Button {
            model.deviceBrowser.selectedFileIDs = [file.id]
            model.startMoveSelectedWithinGarmin()
        } label: {
            Label("Move Within Garmin", systemImage: "folder")
        }
        .disabled(file.type == .folder || model.isManagingDeviceFiles)

        Button(role: .destructive) {
            model.deviceBrowser.selectedFileIDs = [file.id]
            model.requestDeleteSelectedDeviceFiles()
        } label: {
            Label("Delete", systemImage: "trash")
        }
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
            Button("Refresh Devices") {
                model.refreshDevices()
            }
            .buttonStyle(.bordered)
        } else if browser.files.isEmpty {
            Button("Add to Garmin") {
                model.chooseFilesToUploadToDevice()
            }
            .buttonStyle(.bordered)
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
        guard !providers.isEmpty else { return false }

        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            model.uploadFilesToDevice(urls)
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

private struct CollectionRow: View {
    let collection: DeviceCollection

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .lineLimit(1)
                Text("\(collection.totalItemCount) item(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private var systemImage: String {
        switch collection.kind {
        case .allMusic:
            return "music.note.list"
        case .playlist:
            return "list.bullet.rectangle"
        case .album:
            return "opticaldisc"
        case .folder:
            return "folder"
        }
    }
}

private struct OperationBanner: View {
    let operation: DeviceOperation
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if operation.lastError == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(operation.phase)
                    .font(.caption.bold())
                if let lastError = operation.lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if operation.canCancel, operation.lastError == nil, let onCancel {
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }
}

private struct StatusBanner: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
    }
}
