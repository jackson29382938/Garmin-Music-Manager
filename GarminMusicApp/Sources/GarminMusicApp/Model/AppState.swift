import Foundation
import SwiftCrossUI
import GarminMusicCore

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case library = "Library"
    case transfer = "Transfer"
    case onWatch = "On Watch"
    case settings = "Settings"

    var id: Self { self }

    var subtitle: String {
        switch self {
        case .library: return "Import & check music"
        case .transfer: return "Send to your watch"
        case .onWatch: return "Browse what's on the watch"
        case .settings: return "Options & help"
        }
    }
}

/// Observable application state shared across all tabs. Pure Swift + the shared
/// `GarminMusicCore` engine, so it runs unchanged on Windows, macOS, and Linux.
final class AppState: SwiftCrossUI.ObservableObject {
    @SwiftCrossUI.Published var selectedTab: AppTab? = .library

    @SwiftCrossUI.Published var sourceFolder: String = ""
    @SwiftCrossUI.Published var destinationFolder: String = ""
    @SwiftCrossUI.Published var playlistName: String = "Garmin Playlist"

    @SwiftCrossUI.Published var tracks: [LibraryTrack] = []
    @SwiftCrossUI.Published var selectedIDs: Set<UUID> = []
    @SwiftCrossUI.Published var isScanning = false

    @SwiftCrossUI.Published var organization: OrganizationChoice = .flat
    @SwiftCrossUI.Published var overwrite: OverwriteChoice = .skipIdentical
    @SwiftCrossUI.Published var writePlaylist = true

    @SwiftCrossUI.Published var isSending = false
    @SwiftCrossUI.Published var progress: Double = 0

    @SwiftCrossUI.Published var onWatchFiles: [WatchFile] = []

    @SwiftCrossUI.Published var statusMessage = "Add a music folder to get started."

    init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        sourceFolder = home.appendingPathComponent("Music").path
        destinationFolder = home.appendingPathComponent("GarminSync").path
    }

    // MARK: Derived

    var selectedTracks: [LibraryTrack] { tracks.filter { selectedIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedTracks.reduce(0) { $0 + $1.byteCount } }
    var readyCount: Int { tracks.filter { $0.compatibility.status == .ready }.count }
    var warningCount: Int { tracks.filter { $0.compatibility.status == .warning }.count }
    var blockedCount: Int { tracks.filter { $0.compatibility.status == .blocked }.count }
    var canSend: Bool { !selectedTracks.isEmpty && !destinationFolder.isEmpty && !isSending }

    func isSelected(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    func setSelected(_ id: UUID, _ on: Bool) {
        if on { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }

    func selectAllCopyable() {
        selectedIDs = Set(tracks.filter { $0.compatibility.canCopy }.map(\.id))
    }

    func clearSelection() { selectedIDs.removeAll() }

    // MARK: Actions

    func scan() {
        let folder = sourceFolder.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else {
            statusMessage = "Enter a music folder path first."
            return
        }
        isScanning = true
        statusMessage = "Scanning \(folder)…"
        Task { @MainActor in
            let found = await Task.detached { LibraryScanner.scan(folder: URL(fileURLWithPath: folder)) }.value
            self.tracks = found
            self.selectAllCopyable()
            self.isScanning = false
            self.statusMessage = found.isEmpty
                ? "No audio files found under that folder."
                : "Found \(found.count) file(s) — \(self.readyCount) ready, \(self.warningCount) warning, \(self.blockedCount) blocked."
        }
    }

    func send() {
        guard canSend else { return }
        isSending = true
        progress = 0
        let selected = selectedTracks
        let destination = URL(fileURLWithPath: destinationFolder)
        let options = SyncOptions(organization: organization, overwrite: overwrite, writePlaylist: writePlaylist)
        let name = playlistName
        statusMessage = "Sending \(selected.count) track(s)…"
        Task { @MainActor in
            let engine = FolderSyncEngine()
            do {
                let outcome = try await engine.send(
                    tracks: selected,
                    playlistName: name,
                    destination: destination,
                    options: options
                ) { fraction, message in
                    self.progress = fraction
                    self.statusMessage = message
                }
                var summary = "Sent \(outcome.copied) track(s)"
                if outcome.skipped > 0 { summary += ", skipped \(outcome.skipped)" }
                if outcome.playlistPath != nil { summary += ", wrote playlist" }
                summary += " to \(outcome.destinationFolder)."
                self.statusMessage = summary
                self.refreshOnWatch()
                self.selectedTab = .onWatch
            } catch {
                self.statusMessage = "Send failed: \(error.localizedDescription)"
            }
            self.isSending = false
            self.progress = 1
        }
    }

    func refreshOnWatch() {
        let folder = destinationFolder.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else {
            onWatchFiles = []
            return
        }
        Task { @MainActor in
            let files = await Task.detached { LibraryScanner.listWatchFolder(URL(fileURLWithPath: folder)) }.value
            self.onWatchFiles = files
        }
    }
}
