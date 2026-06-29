import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

@main
struct GarminMusicManagerApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel

    private let dashboardColumns = [
        GridItem(.flexible(minimum: 320), spacing: 16),
        GridItem(.flexible(minimum: 320), spacing: 16)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                hero

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        workflowStrip

                        LazyVGrid(columns: dashboardColumns, alignment: .leading, spacing: 16) {
                            DestinationCard()
                            LibraryCard()
                        }

                        TracksCard()
                        SyncCard()
                        StatusLogCard()
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 760)
        .onAppear {
            model.scanDevices()
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 54, height: 54)
                Image(systemName: "music.note.list")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Garmin Music Manager")
                    .font(.largeTitle.bold())
                Text("Prepare local music, catch compatibility problems, and sync a clean playlist to your watch.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                StatusPill(text: model.overallReadinessLabel, status: model.overallReadinessStatus)
                Button {
                    model.scanDevices()
                } label: {
                    Label("Rescan Watches", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1)
        }
    }

    private var workflowStrip: some View {
        HStack(spacing: 12) {
            ProgressStepPill(
                title: "Destination",
                detail: model.destinationURL == nil ? "Choose watch folder" : "Ready",
                systemImage: "applewatch",
                isComplete: model.destinationURL != nil,
                isCurrent: model.destinationURL == nil
            )
            ProgressStepPill(
                title: "Library",
                detail: model.tracks.isEmpty ? "Scan files" : "\(model.tracks.count) loaded",
                systemImage: "folder.badge.plus",
                isComplete: !model.tracks.isEmpty,
                isCurrent: model.destinationURL != nil && model.tracks.isEmpty
            )
            ProgressStepPill(
                title: "Review",
                detail: model.tracks.isEmpty ? "Waiting" : model.issueSummary,
                systemImage: "checklist",
                isComplete: !model.tracks.isEmpty && model.unsupportedTrackCount == 0,
                isCurrent: !model.tracks.isEmpty && model.selectedReadyTrackCount == 0
            )
            ProgressStepPill(
                title: "Sync",
                detail: model.selectedReadyTrackCount == 0 ? "Select tracks" : "\(model.selectedReadyTrackCount) selected",
                systemImage: "arrow.down.doc.fill",
                isComplete: model.lastSyncSummary != nil,
                isCurrent: model.canSync
            )
        }
    }
}

struct DestinationCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        SectionCard(
            title: "Watch destination",
            subtitle: "Pick a detected Garmin volume or manually choose the watch music folder.",
            systemImage: "applewatch"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        model.scanDevices()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }

                    Button {
                        model.chooseDestinationFolder()
                    } label: {
                        Label("Choose Folder…", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if model.devices.isEmpty {
                    EmptyStatePanel(
                        title: "No mounted Garmin volume found",
                        message: "Most Garmin music watches use MTP on macOS. If the watch is exposed by another MTP app, choose its Music folder manually.",
                        systemImage: "exclamationmark.triangle"
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.devices) { device in
                            DeviceChoiceRow(
                                device: device,
                                isSelected: model.destinationURL == device.suggestedMusicFolderURL
                            ) {
                                model.useDevice(device)
                            }
                        }
                    }
                }

                if let destinationURL = model.destinationURL {
                    PathSummary(
                        title: "Current destination",
                        path: destinationURL.path,
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                }
            }
        }
    }
}

struct LibraryCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        SectionCard(
            title: "Music library",
            subtitle: "Load local files and preview which ones are likely Garmin-friendly before copying.",
            systemImage: "music.note"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        model.chooseLibraryFolder()
                    } label: {
                        Label("Scan Folder…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.addFiles()
                    } label: {
                        Label("Add Files…", systemImage: "plus")
                    }

                    Button(role: .destructive) {
                        model.clearTracks()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(model.tracks.isEmpty)
                }

                if let libraryURL = model.libraryURL {
                    PathSummary(
                        title: "Current library",
                        path: libraryURL.path,
                        systemImage: "folder.fill",
                        tint: .accentColor
                    )
                } else {
                    EmptyStatePanel(
                        title: "No library loaded yet",
                        message: "Scan a folder or add individual MP3, AAC, M4A, M4B, or WAV files.",
                        systemImage: "tray"
                    )
                }

                HStack(spacing: 10) {
                    StatTile(title: "Loaded", value: "\(model.tracks.count)", systemImage: "music.note.list")
                    StatTile(title: "Duration", value: model.totalDurationText, systemImage: "clock")
                    StatTile(title: "Size", value: model.totalFileSizeText, systemImage: "externaldrive")
                }
            }
        }
    }
}

struct TracksCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        SectionCard(
            title: "Review tracks",
            subtitle: "Search, filter, and select only the files you want to copy to the watch.",
            systemImage: "checklist"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                toolbar
                stats

                if model.tracks.isEmpty {
                    EmptyStatePanel(
                        title: "Nothing to review",
                        message: "Load a folder or add files to see compatibility warnings here.",
                        systemImage: "music.note.list"
                    )
                    .frame(minHeight: 170)
                } else if model.visibleTracks.isEmpty {
                    EmptyStatePanel(
                        title: "No tracks match the current filters",
                        message: "Clear the search field or change the status filter.",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .frame(minHeight: 170)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.visibleTracks) { track in
                                TrackRow(
                                    track: track,
                                    isSelected: Binding(
                                        get: { model.isTrackSelected(track.id) },
                                        set: { model.setTrackSelected(track.id, isSelected: $0) }
                                    )
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 300, maxHeight: 420)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search title, artist, album, or filename", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            Picker("Status", selection: $model.statusFilter) {
                ForEach(TrackStatusFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 142)

            Picker("Sort", selection: $model.trackSort) {
                ForEach(TrackSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 136)
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            StatChip(title: "Ready", value: "\(model.readyTrackCount)", systemImage: "checkmark.circle.fill", tint: .green)
            StatChip(title: "Warnings", value: "\(model.warningTrackCount)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
            StatChip(title: "Unsupported", value: "\(model.unsupportedTrackCount)", systemImage: "xmark.octagon.fill", tint: .red)
            Spacer()
            Button("Select Ready") {
                model.selectReadyTracks()
            }
            .disabled(model.readyTrackCount == 0)

            Button("Select Compatible") {
                model.selectAllTracks()
            }
            .disabled(model.tracks.isEmpty)

            Button("Deselect All") {
                model.deselectAllTracks()
            }
            .disabled(model.selectedReadyTrackCount == 0)
        }
    }
}

struct SyncCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        SectionCard(
            title: "Sync preview",
            subtitle: "Check the selected transfer before files are copied into a generated GarminMusicManager folder.",
            systemImage: "arrow.down.doc.fill"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    StatTile(title: "Selected", value: "\(model.selectedReadyTrackCount)", systemImage: "checkmark.circle")
                    StatTile(title: "Transfer size", value: model.selectedFileSizeText, systemImage: "externaldrive")
                    StatTile(title: "Duration", value: model.selectedDurationText, systemImage: "clock")
                }

                if let destinationURL = model.destinationURL {
                    PathSummary(
                        title: "Files will copy to",
                        path: destinationURL.appendingPathComponent("GarminMusicManager", isDirectory: true).path,
                        systemImage: "arrow.down.circle.fill",
                        tint: .accentColor
                    )
                } else {
                    PathSummary(
                        title: "Destination needed",
                        path: "Choose a watch music folder before syncing.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                if let progress = model.syncProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress)
                        Text("Copying selected tracks…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastSyncSummary = model.lastSyncSummary {
                    Label(lastSyncSummary, systemImage: "checkmark.seal.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                }

                HStack {
                    Text(model.canSync ? "Ready to copy compatible selected tracks." : model.syncHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        model.syncSelectedTracks()
                    } label: {
                        Label("Sync Selected", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canSync)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
    }
}

struct StatusLogCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        SectionCard(
            title: "Activity log",
            subtitle: "Recent scans, selections, and sync results.",
            systemImage: "terminal"
        ) {
            ScrollView {
                Text(model.statusLog.isEmpty ? "Ready. Pick a Garmin destination and scan local files." : model.statusLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 130)
        }
    }
}

struct DeviceChoiceRow: View {
    let device: GarminDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "applewatch")
                .font(.title3)
                .foregroundStyle(isSelected ? .green : .accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.headline)
                Text(device.suggestedMusicFolderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            if isSelected {
                Button("Selected") { }
                    .buttonStyle(.bordered)
                    .disabled(true)
            } else {
                Button("Use") {
                    action()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.green.opacity(0.12) : Color(nsColor: .windowBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.green.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }
}

struct TrackRow: View {
    let track: MusicTrack
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .disabled(track.status == .unsupported)
                .accessibilityLabel("Select \(track.displayTitle)")

            StatusBadge(status: track.status)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(track.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 16)

                    Text(track.fileExtension.uppercased())
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                }

                if !track.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(track.issues) { issue in
                            IssuePill(issue: issue)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Label(track.url.path, systemImage: "doc")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let fileSizeBytes = track.fileSizeBytes {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(fileSizeBytes), countStyle: .file))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .windowBackgroundColor).opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.38) : Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let content: Content

    init(title: String, subtitle: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.bold())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 8)
    }
}

struct EmptyStatePanel: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PathSummary: View {
    let title: String
    let path: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.bold())
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ProgressStepPill: View {
    let title: String
    let detail: String
    let systemImage: String
    let isComplete: Bool
    let isCurrent: Bool

    private var tint: Color {
        if isComplete { return .green }
        if isCurrent { return .accentColor }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((isCurrent ? Color.accentColor : tint).opacity(isCurrent ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke((isCurrent ? Color.accentColor : tint).opacity(isCurrent ? 0.35 : 0.18), lineWidth: 1)
        )
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct StatChip: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(value)
                .fontWeight(.bold)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(tint)
        .background(tint.opacity(0.10), in: Capsule())
    }
}

struct StatusPill: View {
    let text: String
    let status: TrackStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbolName)
            Text(text)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(status.tint)
        .background(status.tint.opacity(0.12), in: Capsule())
    }
}

struct StatusBadge: View {
    let status: TrackStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbolName)
            Text(status.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(status.tint.opacity(0.12), in: Capsule())
    }
}

struct IssuePill: View {
    let issue: TrackIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: issue.severity.symbolName)
            Text(issue.message)
        }
        .font(.caption)
        .foregroundStyle(issue.severity.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(issue.severity.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var devices: [GarminDevice] = []
    @Published var destinationURL: URL?
    @Published var libraryURL: URL?
    @Published var tracks: [MusicTrack] = []
    @Published var statusLog = ""
    @Published var searchText = ""
    @Published var statusFilter: TrackStatusFilter = .all
    @Published var trackSort: TrackSort = .title
    @Published var syncProgress: Double?
    @Published var lastSyncSummary: String?

    var selectedReadyTrackCount: Int {
        selectedReadyTracks.count
    }

    var selectedReadyTracks: [MusicTrack] {
        tracks.filter { $0.isSelected && $0.status != .unsupported }
    }

    var selectedWarningTrackCount: Int {
        selectedReadyTracks.filter { $0.status == .warning }.count
    }

    var readyTrackCount: Int {
        tracks.filter { $0.status == .ready }.count
    }

    var warningTrackCount: Int {
        tracks.filter { $0.status == .warning }.count
    }

    var unsupportedTrackCount: Int {
        tracks.filter { $0.status == .unsupported }.count
    }

    var canSync: Bool {
        destinationURL != nil && selectedReadyTrackCount > 0 && syncProgress == nil
    }

    var visibleTracks: [MusicTrack] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return tracks
            .filter { track in
                statusFilter.matches(track)
            }
            .filter { track in
                guard !trimmedSearch.isEmpty else { return true }
                return track.searchableText.contains(trimmedSearch)
            }
            .sorted(by: trackSort.areInIncreasingOrder)
    }

    var totalDurationText: String {
        DurationFormatter.formatLong(tracks.compactMap { $0.duration }.reduce(0, +))
    }

    var selectedDurationText: String {
        DurationFormatter.formatLong(selectedReadyTracks.compactMap { $0.duration }.reduce(0, +))
    }

    var totalFileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalFileSizeBytes), countStyle: .file)
    }

    var selectedFileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(selectedFileSizeBytes), countStyle: .file)
    }

    var issueSummary: String {
        if unsupportedTrackCount > 0 {
            return "\(unsupportedTrackCount) unsupported"
        }
        if warningTrackCount > 0 {
            return "\(warningTrackCount) warning\(warningTrackCount == 1 ? "" : "s")"
        }
        return "All ready"
    }

    var overallReadinessLabel: String {
        if destinationURL == nil { return "Needs destination" }
        if tracks.isEmpty { return "Needs music" }
        if selectedReadyTrackCount == 0 { return "Select tracks" }
        if selectedWarningTrackCount > 0 { return "Ready with warnings" }
        return "Ready to sync"
    }

    var overallReadinessStatus: TrackStatus {
        if canSync && selectedWarningTrackCount == 0 { return .ready }
        if destinationURL != nil && !tracks.isEmpty { return .warning }
        return .unsupported
    }

    var syncHelpText: String {
        if destinationURL == nil { return "Choose a destination folder first." }
        if tracks.isEmpty { return "Scan or add local music files first." }
        if selectedReadyTrackCount == 0 { return "Select at least one compatible track." }
        return "Ready."
    }

    private var totalFileSizeBytes: Int {
        tracks.compactMap { $0.fileSizeBytes }.reduce(0, +)
    }

    private var selectedFileSizeBytes: Int {
        selectedReadyTracks.compactMap { $0.fileSizeBytes }.reduce(0, +)
    }

    func scanDevices() {
        devices = GarminVolumeScanner.scanMountedVolumes()
        appendLog("Scanned /Volumes and found \(devices.count) Garmin-like candidate(s).")
    }

    func useDevice(_ device: GarminDevice) {
        destinationURL = device.suggestedMusicFolderURL
        lastSyncSummary = nil
        appendLog("Selected destination: \(device.suggestedMusicFolderURL.path)")
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Garmin music destination folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
            lastSyncSummary = nil
            appendLog("Selected destination manually: \(url.path)")
        }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder containing local music files"
        panel.prompt = "Scan Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            libraryURL = url
            scanLibrary(at: url)
        }
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose music files"
        panel.prompt = "Add Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = MusicInspector.scanExtensions

        if panel.runModal() == .OK {
            let newTracks = panel.urls.map { MusicInspector.inspect(url: $0) }
            mergeTracks(newTracks)
            lastSyncSummary = nil
            appendLog("Added \(newTracks.count) file(s).")
        }
    }

    func scanLibrary(at url: URL) {
        let urls = MusicInspector.findCandidateAudioFiles(in: url)
        let inspected = urls.map { MusicInspector.inspect(url: $0) }
        tracks = inspected.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        searchText = ""
        statusFilter = .all
        lastSyncSummary = nil
        appendLog("Scanned \(url.path). Loaded \(tracks.count) candidate audio file(s).")
    }

    func clearTracks() {
        tracks.removeAll()
        libraryURL = nil
        searchText = ""
        statusFilter = .all
        lastSyncSummary = nil
        appendLog("Cleared loaded tracks.")
    }

    func selectReadyTracks() {
        for index in tracks.indices {
            tracks[index].isSelected = tracks[index].status == .ready
        }
        lastSyncSummary = nil
        appendLog("Selected \(readyTrackCount) track(s) with no warnings.")
    }

    func selectAllTracks() {
        for index in tracks.indices {
            tracks[index].isSelected = tracks[index].status != .unsupported
        }
        lastSyncSummary = nil
        appendLog("Selected all compatible tracks, including files with warnings.")
    }

    func deselectAllTracks() {
        for index in tracks.indices {
            tracks[index].isSelected = false
        }
        lastSyncSummary = nil
        appendLog("Deselected all tracks.")
    }

    func isTrackSelected(_ id: UUID) -> Bool {
        tracks.first(where: { $0.id == id })?.isSelected ?? false
    }

    func setTrackSelected(_ id: UUID, isSelected: Bool) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        guard tracks[index].status != .unsupported else { return }
        tracks[index].isSelected = isSelected
        lastSyncSummary = nil
    }

    func syncSelectedTracks() {
        guard let destinationURL else {
            appendLog("No destination selected.")
            return
        }

        let selected = selectedReadyTracks
        guard !selected.isEmpty else {
            appendLog("No compatible selected tracks to sync.")
            return
        }

        syncProgress = 0
        lastSyncSummary = nil

        do {
            let folderName = "GarminMusicManager"
            let syncFolder = destinationURL.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

            var playlistLines = ["#EXTM3U"]
            var copiedCount = 0

            for (offset, track) in selected.enumerated() {
                let cleanName = FileNameSanitizer.safeFileName(for: track)
                let targetURL = FileNameSanitizer.uniqueURL(in: syncFolder, preferredFileName: cleanName)

                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }

                try FileManager.default.copyItem(at: track.url, to: targetURL)
                copiedCount += 1
                syncProgress = Double(offset + 1) / Double(selected.count)

                let extInfDuration = track.duration.map { String(Int($0.rounded())) } ?? "-1"
                playlistLines.append("#EXTINF:\(extInfDuration),\(track.playlistDisplayName)")
                playlistLines.append(targetURL.lastPathComponent)
            }

            let playlistURL = syncFolder.appendingPathComponent("GarminMusicManager.m3u8")
            try playlistLines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)

            let summary = "Copied \(copiedCount) track(s) and wrote GarminMusicManager.m3u8."
            lastSyncSummary = summary
            appendLog("Copied \(copiedCount) track(s) into \(syncFolder.path)")
            appendLog("Wrote playlist: \(playlistURL.path)")
        } catch {
            appendLog("Sync failed: \(error.localizedDescription)")
        }

        syncProgress = nil
    }

    private func mergeTracks(_ newTracks: [MusicTrack]) {
        var knownURLs = Set(tracks.map { $0.url })
        for track in newTracks where !knownURLs.contains(track.url) {
            tracks.append(track)
            knownURLs.insert(track.url)
        }
        tracks.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        let line = "[\(formatter.string(from: Date()))] \(message)"
        statusLog = statusLog.isEmpty ? line : statusLog + "\n" + line
    }
}

struct GarminDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let volumeURL: URL
    let suggestedMusicFolderURL: URL
}

enum GarminVolumeScanner {
    static func scanMountedVolumes() -> [GarminDevice] {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumeURLs = try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .volumeNameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return volumeURLs.compactMap { volumeURL in
            guard isGarminCandidate(volumeURL) else { return nil }
            let name = volumeURL.lastPathComponent
            let suggested = suggestedMusicFolder(for: volumeURL)
            return GarminDevice(
                id: volumeURL.path,
                name: name,
                volumeURL: volumeURL,
                suggestedMusicFolderURL: suggested
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func isGarminCandidate(_ volumeURL: URL) -> Bool {
        let name = volumeURL.lastPathComponent.lowercased()
        if name.contains("garmin") || name.contains("fenix") || name.contains("forerunner") || name.contains("venu") || name.contains("epix") {
            return true
        }

        let garminFolder = volumeURL.appendingPathComponent("GARMIN", isDirectory: true)
        return FileManager.default.fileExists(atPath: garminFolder.path)
    }

    private static func suggestedMusicFolder(for volumeURL: URL) -> URL {
        let candidates = [
            volumeURL.appendingPathComponent("GARMIN/Music", isDirectory: true),
            volumeURL.appendingPathComponent("Music", isDirectory: true),
            volumeURL.appendingPathComponent("Garmin/Music", isDirectory: true)
        ]

        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return existing
        }

        return candidates[0]
    }
}

struct MusicTrack: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let fileName: String
    let fileExtension: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let fileSizeBytes: Int?
    var issues: [TrackIssue]
    var isSelected: Bool

    var status: TrackStatus {
        if issues.contains(where: { $0.severity == .unsupported }) {
            return .unsupported
        }
        if issues.contains(where: { $0.severity == .warning }) {
            return .warning
        }
        return .ready
    }

    var displayTitle: String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fileName
    }

    var subtitle: String {
        var pieces: [String] = []
        if let artist = artist?.nilIfEmpty { pieces.append(artist) }
        if let album = album?.nilIfEmpty { pieces.append(album) }
        if let duration { pieces.append(DurationFormatter.format(duration)) }
        if let fileSizeBytes { pieces.append(ByteCountFormatter.string(fromByteCount: Int64(fileSizeBytes), countStyle: .file)) }
        return pieces.isEmpty ? "No metadata found" : pieces.joined(separator: " • ")
    }

    var playlistDisplayName: String {
        if let artist = artist?.nilIfEmpty {
            return "\(artist) - \(displayTitle)"
        }
        return displayTitle
    }

    var searchableText: String {
        [displayTitle, artist, album, fileName, fileExtension]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

enum TrackStatus: Hashable {
    case ready
    case warning
    case unsupported

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .warning: return "Warning"
        case .unsupported: return "Unsupported"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unsupported: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .unsupported: return .red
        }
    }
}

enum TrackStatusFilter: String, CaseIterable, Identifiable {
    case all
    case ready
    case warning
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All statuses"
        case .ready: return "Ready"
        case .warning: return "Warnings"
        case .unsupported: return "Unsupported"
        }
    }

    func matches(_ track: MusicTrack) -> Bool {
        switch self {
        case .all: return true
        case .ready: return track.status == .ready
        case .warning: return track.status == .warning
        case .unsupported: return track.status == .unsupported
        }
    }
}

enum TrackSort: String, CaseIterable, Identifiable {
    case title
    case artist
    case album
    case status
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .status: return "Status"
        case .size: return "Size"
        }
    }

    func areInIncreasingOrder(_ lhs: MusicTrack, _ rhs: MusicTrack) -> Bool {
        switch self {
        case .title:
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        case .artist:
            return (lhs.artist ?? "").localizedCaseInsensitiveCompare(rhs.artist ?? "") == .orderedAscending
        case .album:
            return (lhs.album ?? "").localizedCaseInsensitiveCompare(rhs.album ?? "") == .orderedAscending
        case .status:
            return lhs.status.sortOrder < rhs.status.sortOrder
        case .size:
            return (lhs.fileSizeBytes ?? 0) > (rhs.fileSizeBytes ?? 0)
        }
    }
}

private extension TrackStatus {
    var sortOrder: Int {
        switch self {
        case .ready: return 0
        case .warning: return 1
        case .unsupported: return 2
        }
    }
}

struct TrackIssue: Identifiable, Hashable {
    let id = UUID()
    let severity: Severity
    let message: String

    enum Severity: Hashable {
        case warning
        case unsupported

        var symbolName: String {
            switch self {
            case .warning: return "exclamationmark.triangle"
            case .unsupported: return "xmark.octagon"
            }
        }

        var tint: Color {
            switch self {
            case .warning: return .orange
            case .unsupported: return .red
            }
        }
    }
}

enum MusicInspector {
    static let supportedExtensions = ["mp3", "m4a", "aac", "m4b", "wav"]
    static let knownUnsupportedExtensions = ["aif", "aiff", "alac", "flac", "m4p", "ogg", "opus", "wma"]
    static let scanExtensions = supportedExtensions + knownUnsupportedExtensions

    static func findCandidateAudioFiles(in folderURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if scanExtensions.contains(ext) {
                urls.append(url)
            }
        }
        return urls
    }

    static func inspect(url: URL) -> MusicTrack {
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let asset = AVURLAsset(url: url)
        let metadata = asset.commonMetadata

        let title = metadata.commonString(for: .commonKeyTitle)
        let artist = metadata.commonString(for: .commonKeyArtist)
        let album = metadata.commonString(for: .commonKeyAlbumName)
        let durationSeconds = asset.duration.seconds.isFinite ? asset.duration.seconds : nil
        let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize

        var issues: [TrackIssue] = []

        if knownUnsupportedExtensions.contains(ext) {
            issues.append(.init(severity: .unsupported, message: ".\(ext) is not a Garmin-friendly local music format for this MVP."))
        } else if !supportedExtensions.contains(ext) {
            issues.append(.init(severity: .unsupported, message: "Unsupported or unknown file extension: .\(ext)."))
        }

        if ext == "m4a" || ext == "m4b" {
            issues.append(.init(severity: .warning, message: "M4A/M4B may be AAC or Apple Lossless. Garmin-friendly copies should use AAC, not lossless."))
        }

        if title?.nilIfEmpty == nil {
            issues.append(.init(severity: .warning, message: "Missing title metadata; the watch may show the filename."))
        }

        if artist?.nilIfEmpty == nil {
            issues.append(.init(severity: .warning, message: "Missing artist metadata; sorting/display may be less useful."))
        }

        if let fileSize, fileSize > 250_000_000 {
            issues.append(.init(severity: .warning, message: "Large file; consider converting/compressing before copying."))
        }

        return MusicTrack(
            url: url,
            fileName: fileName,
            fileExtension: ext,
            title: title,
            artist: artist,
            album: album,
            duration: durationSeconds,
            fileSizeBytes: fileSize,
            issues: issues,
            isSelected: issues.contains(where: { $0.severity == .unsupported }) == false
        )
    }
}

extension Array where Element == AVMetadataItem {
    func commonString(for key: AVMetadataKey) -> String? {
        first(where: { $0.commonKey == key })?.stringValue
    }
}

enum DurationFormatter {
    static func format(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func formatLong(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        guard totalSeconds > 0 else { return "0m" }

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }
}

enum FileNameSanitizer {
    static func safeFileName(for track: MusicTrack) -> String {
        let base = track.playlistDisplayName.nilIfEmpty ?? track.fileName.replacingOccurrences(of: ".\(track.fileExtension)", with: "")
        let cleanedBase = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = cleanedBase.nilIfEmpty ?? "Track"
        return "\(normalized).\(track.fileExtension)"
    }

    static func uniqueURL(in folderURL: URL, preferredFileName: String) -> URL {
        let preferredURL = folderURL.appendingPathComponent(preferredFileName)
        if !FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName = "\(stem) \(index).\(ext)"
            let candidateURL = folderURL.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return folderURL.appendingPathComponent(UUID().uuidString + "." + ext)
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
