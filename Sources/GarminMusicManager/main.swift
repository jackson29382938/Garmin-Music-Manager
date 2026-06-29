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
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            destinationSection
            librarySection
            trackSection
            actionBar
            logSection
        }
        .padding(20)
        .frame(minWidth: 940, minHeight: 680)
        .onAppear {
            model.scanDevices()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Garmin Music Manager")
                .font(.largeTitle.bold())
            Text("Copy local music to a Garmin watch folder and generate a simple playlist.")
                .foregroundStyle(.secondary)
        }
    }

    private var destinationSection: some View {
        GroupBox("Watch / Destination") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Rescan Garmin Volumes") {
                        model.scanDevices()
                    }
                    Button("Choose Destination Folder…") {
                        model.chooseDestinationFolder()
                    }
                    Spacer()
                    if let destinationURL = model.destinationURL {
                        Text(destinationURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.devices.isEmpty {
                    Label("No Garmin-like mounted volume found. If your watch uses MTP, expose or choose its music folder manually.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        HStack(alignment: .top) {
                            Image(systemName: "applewatch")
                                .font(.title3)
                            VStack(alignment: .leading) {
                                Text(device.name)
                                    .font(.headline)
                                Text(device.suggestedMusicFolderURL.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Use") {
                                model.useDevice(device)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let destinationURL = model.destinationURL {
                    Divider()
                    Text("Destination: \(destinationURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var librarySection: some View {
        GroupBox("Music Library") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Scan Music Folder…") {
                        model.chooseLibraryFolder()
                    }
                    Button("Add Files…") {
                        model.addFiles()
                    }
                    Button("Clear") {
                        model.clearTracks()
                    }
                    Spacer()
                    Text("\(model.tracks.count) files loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let libraryURL = model.libraryURL {
                    Text("Library: \(libraryURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Choose a folder of local MP3/AAC/M4A/M4B/WAV files, or add individual files.")
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
                        description: Text("Scan a folder or add files to start checking Garmin compatibility.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    HStack {
                        Button("Select Ready") {
                            model.selectReadyTracks()
                        }
                        Button("Select All") {
                            model.selectAllTracks()
                        }
                        Button("Deselect All") {
                            model.deselectAllTracks()
                        }
                        Spacer()
                        Text("\(model.selectedReadyTrackCount) ready selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach($model.tracks) { $track in
                                TrackRow(track: $track)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 240)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button {
                model.syncSelectedTracks()
            } label: {
                Label("Sync Selected to Watch Folder", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSync)

            Spacer()

            Text(model.canSync ? "Ready to copy compatible selected tracks." : "Choose a destination and select compatible tracks to sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        GroupBox("Status") {
            ScrollView {
                Text(model.statusLog.isEmpty ? "Ready." : model.statusLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 92)
        }
    }
}

struct TrackRow: View {
    @Binding var track: MusicTrack

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $track.isSelected)
                .labelsHidden()
                .disabled(track.status == .unsupported)

            Image(systemName: track.status.symbolName)
                .foregroundStyle(track.status.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(track.displayTitle)
                        .font(.headline)
                    Spacer()
                    Text(track.fileExtension.uppercased())
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }

                Text(track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !track.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(track.issues) { issue in
                            Label(issue.message, systemImage: issue.severity.symbolName)
                                .font(.caption)
                                .foregroundStyle(issue.severity.tint)
                        }
                    }
                }

                Text(track.url.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var devices: [GarminDevice] = []
    @Published var destinationURL: URL?
    @Published var libraryURL: URL?
    @Published var tracks: [MusicTrack] = []
    @Published var statusLog = ""

    var selectedReadyTrackCount: Int {
        tracks.filter { $0.isSelected && $0.status != .unsupported }.count
    }

    var canSync: Bool {
        destinationURL != nil && selectedReadyTrackCount > 0
    }

    func scanDevices() {
        devices = GarminVolumeScanner.scanMountedVolumes()
        appendLog("Scanned /Volumes and found \(devices.count) Garmin-like candidate(s).")
    }

    func useDevice(_ device: GarminDevice) {
        destinationURL = device.suggestedMusicFolderURL
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
            appendLog("Added \(newTracks.count) file(s).")
        }
    }

    func scanLibrary(at url: URL) {
        let urls = MusicInspector.findCandidateAudioFiles(in: url)
        let inspected = urls.map { MusicInspector.inspect(url: $0) }
        tracks = inspected.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        appendLog("Scanned \(url.path). Loaded \(tracks.count) candidate audio file(s).")
    }

    func clearTracks() {
        tracks.removeAll()
        appendLog("Cleared loaded tracks.")
    }

    func selectReadyTracks() {
        for index in tracks.indices {
            tracks[index].isSelected = tracks[index].status != .unsupported
        }
        appendLog("Selected all tracks that are not marked unsupported.")
    }

    func selectAllTracks() {
        for index in tracks.indices {
            tracks[index].isSelected = tracks[index].status != .unsupported
        }
        appendLog("Selected all compatible or warning tracks.")
    }

    func deselectAllTracks() {
        for index in tracks.indices {
            tracks[index].isSelected = false
        }
        appendLog("Deselected all tracks.")
    }

    func syncSelectedTracks() {
        guard let destinationURL else {
            appendLog("No destination selected.")
            return
        }

        let selected = tracks.filter { $0.isSelected && $0.status != .unsupported }
        guard !selected.isEmpty else {
            appendLog("No compatible selected tracks to sync.")
            return
        }

        do {
            let folderName = "GarminMusicManager"
            let syncFolder = destinationURL.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

            var playlistLines = ["#EXTM3U"]
            var copiedCount = 0

            for track in selected {
                let cleanName = FileNameSanitizer.safeFileName(for: track)
                let targetURL = FileNameSanitizer.uniqueURL(in: syncFolder, preferredFileName: cleanName)

                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }

                try FileManager.default.copyItem(at: track.url, to: targetURL)
                copiedCount += 1

                let extInfDuration = track.duration.map { String(Int($0.rounded())) } ?? "-1"
                playlistLines.append("#EXTINF:\(extInfDuration),\(track.playlistDisplayName)")
                playlistLines.append(targetURL.lastPathComponent)
            }

            let playlistURL = syncFolder.appendingPathComponent("GarminMusicManager.m3u8")
            try playlistLines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)

            appendLog("Copied \(copiedCount) track(s) into \(syncFolder.path)")
            appendLog("Wrote playlist: \(playlistURL.path)")
        } catch {
            appendLog("Sync failed: \(error.localizedDescription)")
        }
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
}

enum TrackStatus: Hashable {
    case ready
    case warning
    case unsupported

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
