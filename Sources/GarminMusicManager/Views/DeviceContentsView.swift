import GarminMusicCore
import SwiftUI
import UniformTypeIdentifiers

struct DeviceContentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isUploadDropTarget = false

    private var browser: DeviceBrowserStore {
        model.deviceBrowser
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let operation = browser.operation {
                OperationBanner(operation: operation)
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
                    title: "Connect a Garmin or choose a folder",
                    message: browser.statusMessage ?? "Choose a Garmin destination before adding music."
                )
            } else if browser.isRefreshing && browser.files.isEmpty {
                loadingState
            } else if browser.files.isEmpty {
                emptyState(
                    title: browser.browseMode == .advancedStorage ? "No files found" : "No music found",
                    message: browser.statusMessage ?? (browser.backendKind == .mtp
                        ? "Drop Mac tracks here or use Add to Garmin."
                        : "Drop Mac tracks here or use Add to Garmin.")
                )
            } else {
                HStack(spacing: 0) {
                    collectionSidebar
                    Divider()
                    fileTable
                }
            }
        }
        .frame(minHeight: 300, idealHeight: 380, maxHeight: .infinity)
        .background(isUploadDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isUploadDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
                .padding(4)
        }
        .onDrop(of: [.fileURL], isTargeted: $isUploadDropTarget) { providers in
            handleUploadDrop(providers)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("Garmin Library")
                        .font(.headline)
                } icon: {
                    Image(systemName: "applewatch")
                }
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if model.advancedStorageExplorerEnabled {
                Picker("Browse mode", selection: Binding(
                    get: { browser.browseMode },
                    set: { model.switchDeviceBrowseMode(to: $0) }
                )) {
                    Text("Music").tag(DeviceBrowseMode.musicOnly)
                    Text("Storage").tag(DeviceBrowseMode.advancedStorage)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            deviceActions
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
            model.moveSelectedDeviceFiles()
        } label: {
            Label("Move", systemImage: "folder")
        }
        .disabled(!model.canMoveSelectedDeviceFiles)
        .help(browser.supportsMove ? "Move selected files" : "Move is not supported over this MTP connection")
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
        .frame(width: 240)
    }

    private var fileTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search files", text: $model.deviceBrowser.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)

                Picker("Sort", selection: $model.deviceBrowser.sortOrder) {
                    ForEach(DeviceFileSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)

                Spacer()

                Text("\(browser.displayedFiles.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)

            Table(browser.displayedFiles, selection: $model.deviceBrowser.selectedFileIDs) {
                TableColumn("Name") { file in
                    Label(file.name, systemImage: systemImage(for: file))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contextMenu {
                            Button {
                                model.deviceBrowser.selectedFileIDs = [file.id]
                                model.copySelectedDeviceFilesToMac()
                            } label: {
                                Label("Copy to Mac", systemImage: "square.and.arrow.down")
                            }

                            Button {
                                model.deviceBrowser.selectedFileIDs = [file.id]
                                model.moveSelectedDeviceFiles()
                            } label: {
                                Label("Move", systemImage: "folder")
                            }
                            .disabled(!browser.supportsMove)

                            Button(role: .destructive) {
                                model.deviceBrowser.selectedFileIDs = [file.id]
                                model.requestDeleteSelectedDeviceFiles()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
                }

                TableColumn("Type") { file in
                    Text(typeText(for: file))
                        .foregroundStyle(.secondary)
                }
            }

            if !browser.unmatchedItemsForSelectedCollection.isEmpty {
                unmatchedRows
            }
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.25))
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(browser.browseMode == .advancedStorage ? "Reading Garmin storage..." : "Reading Garmin music...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
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
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
