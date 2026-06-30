import SwiftUI

struct DeviceContentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedCollectionID = "all"

    private let allCollectionID = "all"

    private var selectedPlaylist: DevicePlaylist? {
        guard selectedCollectionID != allCollectionID else { return nil }
        return model.devicePlaylists.first { $0.id == selectedCollectionID }
    }

    private var visibleFiles: [DeviceAudioFile] {
        guard let selectedPlaylist else { return model.deviceFiles }
        let names = Set(selectedPlaylist.trackFileNames.map { $0.lowercased() })
        let matches = model.deviceFiles.filter { names.contains($0.fileName.lowercased()) }
        return matches
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
                .disabled(model.isBrowsingDevice)
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
        .onAppear {
            if model.activeDestination == nil, model.canAttemptMTP, !model.isMTPLibraryLoaded {
                model.browseGarminMusicLibrary()
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

                ForEach(model.devicePlaylists) { playlist in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(playlist.name, systemImage: playlist.source == .mtpPlaylist ? "list.bullet.rectangle" : "folder")
                            .lineLimit(1)
                        Text("\(playlist.trackCount) track(s) • \(sourceDescription(for: playlist.source))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(playlist.id)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: model.devicePlaylists.isEmpty ? 0 : 230)
        .clipped()
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPlaylist?.name ?? "All Music")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text("\(visibleFiles.count) visible • \(model.selectedDeviceFileIDs.count) selected")
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

            List(visibleFiles, selection: $model.selectedDeviceFileIDs) { file in
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

            if let selectedPlaylist, visibleFiles.isEmpty, !selectedPlaylist.trackFileNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reported tracks")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(selectedPlaylist.trackFileNames, id: \.self) { trackName in
                                Text(trackName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 90)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            } else if let selectedPlaylist, visibleFiles.count < selectedPlaylist.trackFileNames.count {
                Text("\(selectedPlaylist.trackFileNames.count) track(s) reported by this collection; \(visibleFiles.count) can be matched to browsable files.")
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
            return "folder"
        case .mtpPlaylist:
            return "playlist"
        }
    }
}
