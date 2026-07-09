import AppKit
import Foundation
import GarminMusicCore
import UniformTypeIdentifiers

/// Owns Mac-side library import, selection helpers, Apple Music loading, and queue restore.
/// Published UI state (`tracks`, `searchText`, sheets) stays on `AppModel`.
@MainActor
final class MacLibrarySession {
    private let scanner = MusicScanner()
    private let libraryImportCoordinator = LibraryImportCoordinator()
    private let appleMusic = AppleMusicLibrary()
    private let libraryQueueStore: LibraryQueueStore

    init(libraryQueueStore: LibraryQueueStore = LibraryQueueStore()) {
        self.libraryQueueStore = libraryQueueStore
    }

    // MARK: - Computed helpers (pure)

    func syncableTracks(
        from tracks: [AudioTrack],
        skipDuplicates: Bool = false
    ) -> [AudioTrack] {
        tracks.filter { track in
            guard track.compatibility.canCopy, track.isSelected else { return false }
            if skipDuplicates, track.isDuplicateOnDevice { return false }
            return true
        }
    }

    /// Applies import selection policy after scan / duplicate detection.
    func applyImportSelection(
        _ tracks: [AudioTrack],
        mode: ImportSelectionMode
    ) -> [AudioTrack] {
        tracks.map { track in
            var copy = track
            switch mode {
            case .allReady:
                copy.isSelected = track.compatibility.canCopy
            case .none:
                copy.isSelected = false
            case .nonDuplicates:
                copy.isSelected = track.compatibility.canCopy && !track.isDuplicateOnDevice
            }
            return copy
        }
    }

    func applyAutoDeselectDuplicates(_ tracks: [AudioTrack], enabled: Bool) -> [AudioTrack] {
        guard enabled else { return tracks }
        return tracks.map { track in
            var copy = track
            if track.isDuplicateOnDevice {
                copy.isSelected = false
            }
            return copy
        }
    }

    func blockedTracks(from tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.filter { !$0.compatibility.canCopy }
    }

    func filteredTracks(from tracks: [AudioTrack], searchText: String) -> [AudioTrack] {
        guard !searchText.isEmpty else { return tracks }
        let query = searchText.lowercased()
        return tracks.filter {
            $0.displayName.lowercased().contains(query)
                || $0.fileName.lowercased().contains(query)
                || ($0.artist?.lowercased().contains(query) ?? false)
                || ($0.album?.lowercased().contains(query) ?? false)
        }
    }

    func macLibraryLocationDescription(for tracks: [AudioTrack]) -> String {
        if tracks.isEmpty {
            return "No Mac music loaded"
        }
        let folders = Set(tracks.map { $0.url.deletingLastPathComponent().path })
        if folders.count == 1, let folder = folders.first {
            return folder
        }
        return "\(folders.count) Mac folders"
    }

    // MARK: - Panel pickers

    func chooseMusicFiles(onPick: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose music files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MusicScanner.supportedPickerTypes

        if panel.runModal() == .OK {
            onPick(panel.urls)
        }
    }

    func chooseMusicFolder(onPick: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder containing music"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            onPick([url])
        }
    }

    /// Returns the chosen playlist URL, if any.
    func chooseM3UPlaylistURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a playlist file"
        panel.message = "Import local tracks listed in an .m3u or .m3u8 file."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        if panel.allowedContentTypes.isEmpty {
            panel.allowsOtherFileTypes = true
        }

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Import / queue

    struct ImportResult {
        var tracks: [AudioTrack]
        var addedCount: Int
        var playlistsExpanded: Int
        var message: String?
        /// When replacing the whole queue (Apple Music playlist prepare).
        var replaced: Bool
    }

    /// Expands URLs (folders, playlists) and merges into the existing track list.
    func addFiles(
        _ urls: [URL],
        into tracks: [AudioTrack],
        library: LibrarySettings = .default,
        setScanning: (Bool) -> Void
    ) async -> ImportResult {
        guard !urls.isEmpty else {
            return ImportResult(tracks: tracks, addedCount: 0, playlistsExpanded: 0, message: nil, replaced: false)
        }

        setScanning(true)
        defer { setScanning(false) }

        let expansion = libraryImportCoordinator.expandImportURLs(urls)
        guard !expansion.audioURLs.isEmpty else {
            let message: String?
            if expansion.playlistsExpanded > 0 {
                message = "No local tracks found in the selected playlist(s). Remote/streaming entries are skipped."
            } else {
                message = nil
            }
            return ImportResult(
                tracks: tracks,
                addedCount: 0,
                playlistsExpanded: expansion.playlistsExpanded,
                message: message,
                replaced: false
            )
        }

        let lib = library.clamped
        var scanned = await scanner.scanFiles(
            expansion.audioURLs,
            fastImport: lib.fastImport,
            maxConcurrency: lib.importConcurrency
        )
        scanned = applyImportSelection(scanned, mode: lib.importSelectionMode)
        let merged = libraryImportCoordinator.mergeTracks(existing: tracks, newTracks: scanned)
        var message = "Added \(scanned.count) file(s)."
        if expansion.playlistsExpanded > 0 {
            message += " Expanded \(expansion.playlistsExpanded) playlist file(s)."
        }
        if lib.fastImport {
            message += " (fast import)"
        }
        return ImportResult(
            tracks: merged,
            addedCount: scanned.count,
            playlistsExpanded: expansion.playlistsExpanded,
            message: message,
            replaced: false
        )
    }

    /// Replaces the queue with scanned tracks from the given URLs (order preserved).
    func replaceTracks(
        with urls: [URL],
        library: LibrarySettings = .default,
        setScanning: (Bool) -> Void
    ) async -> ImportResult {
        guard !urls.isEmpty else {
            return ImportResult(tracks: [], addedCount: 0, playlistsExpanded: 0, message: nil, replaced: true)
        }
        setScanning(true)
        defer { setScanning(false) }

        let lib = library.clamped
        var scanned = await scanner.scanFiles(
            urls,
            fastImport: lib.fastImport,
            maxConcurrency: lib.importConcurrency
        )
        scanned = applyImportSelection(scanned, mode: lib.importSelectionMode)
        return ImportResult(
            tracks: scanned,
            addedCount: scanned.count,
            playlistsExpanded: 0,
            message: nil,
            replaced: true
        )
    }

    func removeTracks(at offsets: IndexSet, filtered: [AudioTrack], from tracks: [AudioTrack]) -> [AudioTrack] {
        let idsToRemove = Set(offsets.map { filtered[$0].id })
        return tracks.filter { !idsToRemove.contains($0.id) }
    }

    func removeTracks(ids: Set<UUID>, from tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.filter { !ids.contains($0.id) }
    }

    func selectAllReady(in tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.map { track in
            var copy = track
            copy.isSelected = track.compatibility.canCopy
            return copy
        }
    }

    func deselectAll(in tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.map { track in
            var copy = track
            copy.isSelected = false
            return copy
        }
    }

    func selectOnly(ids: Set<UUID>, in tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.map { track in
            var copy = track
            copy.isSelected = ids.contains(track.id) && track.compatibility.canCopy
            return copy
        }
    }

    // MARK: - Queue persistence

    func saveQueue(_ tracks: [AudioTrack]) {
        libraryQueueStore.save(tracks: tracks)
    }

    func clearPersistedQueue() {
        libraryQueueStore.clear()
    }

    /// Restores tracks that still exist on disk from the last session.
    func restoreQueue(
        library: LibrarySettings = .default,
        setScanning: (Bool) -> Void
    ) async -> ImportResult? {
        guard library.restoreQueueOnLaunch else { return nil }
        let restored = libraryQueueStore.restoreExisting()
        guard !restored.urls.isEmpty else { return nil }

        setScanning(true)
        defer { setScanning(false) }

        let lib = library.clamped
        var scanned = await scanner.scanFiles(
            restored.urls,
            fastImport: lib.fastImport,
            maxConcurrency: lib.importConcurrency
        )
        for index in scanned.indices {
            let path = scanned[index].url.standardizedFileURL.path
            if let selected = restored.selection[path] {
                scanned[index].isSelected = selected && scanned[index].compatibility.canCopy
            }
        }
        return ImportResult(
            tracks: scanned,
            addedCount: scanned.count,
            playlistsExpanded: 0,
            message: "Restored \(scanned.count) track(s) from the previous session.",
            replaced: true
        )
    }

    // MARK: - Apple Music

    enum AppleMusicLoadOutcome {
        case loaded(MusicLibrarySnapshot, message: String)
        case failed(message: String)
    }

    func loadAppleMusicLibrary() async -> AppleMusicLoadOutcome {
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) { [appleMusic] in
                try appleMusic.loadSnapshot()
            }.value
            let message = "Loaded Apple Music library: \(snapshot.playlists.count) playlists, \(snapshot.albums.count) albums."
            return .loaded(snapshot, message: message)
        } catch {
            return .failed(message: "Apple Music load failed: \(error.localizedDescription)")
        }
    }

    struct AppleMusicImportPlan {
        var urls: [URL]
        var skipped: Int
        var playlistName: String?
        var logMessages: [String]
        var closeBrowser: Bool
        var replaceQueue: Bool
    }

    func planImportLibraryTracks(
        trackIDs: [String],
        musicLibrary: MusicLibrarySnapshot
    ) -> AppleMusicImportPlan {
        let urls = musicLibrary.importableURLs(for: trackIDs)
        let total = trackIDs.count
        let skipped = total - urls.count
        var logs: [String] = []
        if urls.isEmpty {
            logs.append("No importable local files in selection (\(skipped) cloud-only or DRM-protected).")
            return AppleMusicImportPlan(
                urls: [],
                skipped: skipped,
                playlistName: nil,
                logMessages: logs,
                closeBrowser: false,
                replaceQueue: false
            )
        }
        if skipped > 0 {
            logs.append("Skipping \(skipped) cloud-only/DRM track(s); importing \(urls.count).")
        }
        return AppleMusicImportPlan(
            urls: urls,
            skipped: skipped,
            playlistName: nil,
            logMessages: logs,
            closeBrowser: true,
            replaceQueue: false
        )
    }

    func planAppleMusicPlaylist(
        playlistID: String,
        musicLibrary: MusicLibrarySnapshot
    ) -> AppleMusicImportPlan {
        guard let playlist = musicLibrary.playlists.first(where: { $0.id == playlistID }) else {
            return AppleMusicImportPlan(
                urls: [],
                skipped: 0,
                playlistName: nil,
                logMessages: ["Choose an Apple Music playlist first."],
                closeBrowser: false,
                replaceQueue: false
            )
        }

        let urls = musicLibrary.importableURLs(for: playlist.trackIDs)
        let skipped = playlist.trackIDs.count - urls.count
        guard !urls.isEmpty else {
            return AppleMusicImportPlan(
                urls: [],
                skipped: skipped,
                playlistName: nil,
                logMessages: [
                    "No importable local files in \(playlist.name) (\(skipped) cloud-only or DRM-protected)."
                ],
                closeBrowser: false,
                replaceQueue: false
            )
        }

        let skippedText = skipped > 0 ? " Skipped \(skipped) cloud-only/DRM track(s)." : ""
        return AppleMusicImportPlan(
            urls: urls,
            skipped: skipped,
            playlistName: playlist.name,
            logMessages: [
                "Prepared \(playlist.name) for Garmin sync with \(urls.count) local track(s).\(skippedText)"
            ],
            closeBrowser: true,
            replaceQueue: true
        )
    }
}
