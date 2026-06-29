import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            destinationSection
            librarySection
            trackSection
            syncSection
            diagnosticsSection
        }
        .padding(20)
        .frame(minWidth: 1080, minHeight: 800)
        .onAppear { model.scanDevices() }
        .sheet(item: metadataSheetBinding) { track in
            MetadataRepairSheet(track: track)
                .environmentObject(model)
        }
    }

    private var metadataSheetBinding: Binding<MusicTrack?> {
        Binding(
            get: { model.selectedTrackForMetadata },
            set: { newValue in
                if newValue == nil { model.cancelMetadataRepair() }
            }
        )
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Garmin Music Manager")
                    .font(.largeTitle.bold())
                Text("Local Garmin music sync with MTP detection, audio conversion, metadata repair, and copyable debug logs.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(model.selectedReadyTrackCount) ready selected")
                    .font(.headline)
                Text(model.selectedBytesText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSection: some View {
        GroupBox("Watch / Destination") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Rescan Volumes") { model.scanDevices() }
                    Button("Choose Folder…") { model.chooseDestinationFolder() }
                    Button("Validate") { model.validateDestinationForUser() }
                        .disabled(model.destinationURL == nil)
                    Button("Detect MTP") { model.detectMTPDevice() }
                    Spacer()
                    destinationStatusBadge
                }

                Toggle("Experimental MTP sync using libmtp command-line tools", isOn: $model.useExperimentalMTP)
                    .font(.caption)
                Text("MTP status: \(model.mtpStatusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if model.devices.isEmpty {
                    Label("No Garmin-like mounted volume found. For MTP watches, use Detect MTP or choose a folder exposed by an MTP helper app.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        HStack(alignment: .top) {
                            Image(systemName: device.kind == .mtp ? "cable.connector" : "applewatch")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.headline)
                                Text(device.suggestedMusicFolderURL.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Use") { model.useDevice(device) }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let destinationURL = model.destinationURL, !model.useExperimentalMTP {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Destination: \(destinationURL.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let freeSpaceText = model.destinationFreeSpaceText {
                            Text("Available space: \(freeSpaceText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var destinationStatusBadge: some View {
        switch model.destinationHealth {
        case .unknown:
            Label("Not validated", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .valid:
            Label("Writable", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .warning:
            Label("Warning", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .invalid:
            Label("Invalid", systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var librarySection: some View {
        GroupBox("Music Library") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Scan Music Folder…") { model.chooseLibraryFolder() }
                    Button("Add Files…") { model.addFiles() }
                    Button("Clear") { model.clearTracks() }
                    Spacer()
                    Text("\(model.tracks.count) files loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter tracks, artists, albums, statuses, or warnings", text: $model.filterText)
                        .textFieldStyle(.roundedBorder)
                }

                if let libraryURL = model.libraryURL {
                    Text("Library: \(libraryURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Choose a folder of local audio files, or add individual files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var trackSection: some View {
        GroupBox("Tracks") {
            VStack(alignment: .leading, spacing: 8) {
                if model.tracks.isEmpty {
                    ContentUnavailableView(
                        "No Music Loaded",
                        systemImage: "music.note.list",
                        description: Text("Scan a folder or add files to check compatibility.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    HStack {
                        Button("Select Ready") { model.selectReadyTracks() }
                        Button("Select Warnings Too") { model.selectAllNonUnsupportedTracks() }
                        Button("Deselect All") { model.deselectAllTracks() }
                        Divider().frame(height: 20)
                        Picker("Convert", selection: $model.conversionPreset) {
                            ForEach(ConversionPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .frame(width: 220)
                        Button("Convert Selected") { model.convertSelectedTracks() }
                        Spacer()
                        Text("Showing \(model.filteredTracks.count) of \(model.tracks.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.filteredTracks) { track in
                                if let binding = model.binding(for: track) {
                                    TrackRow(track: binding) {
                                        model.beginMetadataRepair(for: track)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 270)
                }
            }
        }
    }

    private var syncSection: some View {
        GroupBox("Sync Preflight") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { model.previewSync() } label: {
                        Label("Preview Sync", systemImage: "list.bullet.clipboard")
                    }
                    .disabled(!model.canSync)

                    Button { model.syncSelectedTracks() } label: {
                        Label("Sync Selected", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSync)

                    Spacer()
                    Text(model.canSync ? "Preflight runs before copy." : "Choose a destination/MTP mode and select compatible tracks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !model.preflightMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.preflightMessages, id: \.self) { message in
                            Label(message, systemImage: "checklist")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        GroupBox("Error Log / Debugging") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Copy Debug Log") { model.copyDebugLogToClipboard() }
                    Button("Export Debug Log…") { model.exportDebugLog() }
                    Button("Open Log Folder") { model.openLogFolder() }
                    Button("Clear Visible Log") { model.clearVisibleLog() }
                    Spacer()
                    Text(model.logFileURL.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                ScrollView {
                    Text(model.formattedDebugLog.isEmpty ? "No log entries yet." : model.formattedDebugLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 130)
            }
        }
    }
}
