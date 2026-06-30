import SwiftUI

struct DeviceContentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedCollectionID = "all"
    @State private var fileSearchText = ""
    @State private var sortOrder = DeviceFileSort.nameAscending

    private let allCollectionID = "all"

    private var selectedPlaylist: DevicePlaylist? {
        guard selectedCollectionID != allCollectionID else { return nil }
        return model.devicePlaylists.first { $0.id == selectedCollectionID }
    }

    private var collectionFilteredFiles: [DeviceAudioFile] {
        guard let selectedPlaylist else { return model.deviceFiles }
        let names = Set(selectedPlaylist.trackFileNames.map { $0.lowercased() })
        return model.deviceFiles.filter { names.contains($0.fileName.lowercased()) }
    }

    private var displayedFiles: [DeviceAudioFile] {
        var files = collectionFilteredFiles
        if !fileSearchText.isEmpty {
            let query = fileSearchText.lowercased()
            files = files.filter {
                $0.fileName.lowercased().contains(query)
                    || ($0.folderName?.lowercased().contains(query) ?? false)
            }
        }

        switch sortOrder {
        case .nameAscending:
            return files.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
        case .nameDescending:
            return files.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedDescending }
        case .sizeAscending:
            return files.sorted { $0.byteCount < $1.byteCount }
        case .sizeDescending:
            return files.sorted { $0.byteCount > $1.byteCount }
        case .folderAscending:
            return files.sorted {
                let lhs = $0.folderName ?? ""
                let rhs = $1.folderName ?? ""
                if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
                    return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }

    private var filteredPlaylists: [DevicePlaylist] {
        guard !fileSearchText.isEmpty else { return model.devicePlaylists }
        let query = fileSearchText.lowercased()
        return model.devicePlaylists.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.isMTPLibraryMode ? "On Garmin (MTP)" : "On Device")
                    .font(.headline)
                    .fixedSize()
                if let storage = model.storageInfo {
                    Text("\(storage.audioFileCount) files • \(storage.audioSizeDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Refresh") {
                    if model.isMTPLibraryMode || model.canAttemptMTP {
                        model.browseGarminMusicLibrary()
                    } else if model.activeDestination == nil {
                        model.refreshDevices()
                    } else {
                        model.refreshDeviceContents()
                    }
                }
                .disabled(model.isBrowsingDevice || model.isManagingDeviceFiles)
                .fixedSize()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if model.isBrowsingDevice && model.deviceFiles.isEmpty && model.devicePlaylists.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading Garmin music library over MTP…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            } else if model.activeDestination == nil && !model.isMTPLibraryMode {
                Text(model.deviceBrowseMessage ?? "Connect a Garmin over USB or choose a destination folder to browse existing audio files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else if model.deviceFiles.isEmpty && model.devicePlaylists.isEmpty {
                Text(model.deviceBrowseMessage ?? (model.isMTPLibraryMode
                    ? "No music or playlists found on the Garmin yet."
                    : "No audio files found in the destination folder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else {
                HStack(spacing: 0) {
                    collectionList
                    Divider()
                    fileList
                }
                .frame(minHeight: 240, idealHeight: 320, maxHeight: .infinity)
                .padding(.horizontal, 4)
            }
        }
        .onChange(of: model.devicePlaylists) { _, playlists in
            if selectedCollectionID != allCollectionID,
               !playlists.contains(where: { $0.id == selectedCollectionID }) {
                selectedCollectionID = allCollectionID
            }
        }
    }

    private var collectionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collections")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            List(selection: $selectedCollectionID) {
                Label("All Music", systemImage: "music.note.list")
                    .tag(allCollectionID)

                if !filteredPlaylists.isEmpty {
                    Section("Playlists") {
                        ForEach(filteredPlaylists) { playlist in
                            collectionRow(playlist)
                                .tag(playlist.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 240)
    }

    private func collectionRow(_ playlist: DevicePlaylist) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(playlist.name, systemImage: playlist.source == .mtpPlaylist ? "list.bullet.rectangle" : "folder")
                .lineLimit(1)
            Text("\(playlist.trackCount) track(s) • \(sourceDescription(for: playlist.source))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPlaylist?.name ?? "All Music")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text("\(displayedFiles.count) visible • \(model.selectedDeviceFileIDs.count) selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    model.copySelectedDeviceFilesToMac()
                } label: {
                    Label("Copy to Mac", systemImage: "square.and.arrow.down")
                }
                .disabled(model.selectedDeviceFileIDs.isEmpty || model.isManagingDeviceFiles)
                .help("Copy selected files from the Garmin to a folder on this Mac")

                Button {
                    model.moveSelectedDeviceFiles()
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .disabled(!model.canMoveSelectedDeviceFiles)
                .help(model.isMTPLibraryMode ? "Moving directly over Garmin MTP is not supported; copy/delete or re-sync instead" : "Move selected files to another folder")

                Button(role: .destructive) {
                    model.showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.selectedDeviceFileIDs.isEmpty || model.isManagingDeviceFiles)
                .help("Delete selected files from the Garmin")
            }
            .padding(.horizontal, 8)

            HStack(spacing: 8) {
                TextField("Filter songs", text: $fileSearchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Sort", selection: $sortOrder) {
                    ForEach(DeviceFileSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Location")
                    .frame(width: 160, alignment: .leading)
                Text("Size")
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            List(displayedFiles, selection: $model.selectedDeviceFileIDs) { file in
                HStack(spacing: 8) {
                    Label(file.fileName, systemImage: "music.note")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(file.folderName ?? "Music")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 160, alignment: .leading)

                    Text(file.sizeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .contextMenu {
                    Button {
                        model.selectedDeviceFileIDs = [file.id]
                        model.copySelectedDeviceFilesToMac()
                    } label: {
                        Label("Copy to Mac", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        model.selectedDeviceFileIDs = [file.id]
                        model.moveSelectedDeviceFiles()
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .disabled(model.isMTPLibraryMode)

                    Button(role: .destructive) {
                        model.selectedDeviceFileIDs = [file.id]
                        model.showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            if let selectedPlaylist, displayedFiles.isEmpty, !selectedPlaylist.trackFileNames.isEmpty {
                Text("This playlist lists \(selectedPlaylist.trackCount) track(s), but none matched the current Garmin file index. Try Refresh.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    private func sourceDescription(for source: DevicePlaylist.Source) -> String {
        switch source {
        case .m3u8:
            return "M3U8"
        case .folder:
            return "album/folder"
        case .mtpPlaylist:
            return "playlist"
        }
    }
}
