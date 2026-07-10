import AppKit
import Foundation
import UniformTypeIdentifiers

/// A single entry in the Mac folder browser (folder, audio, playlist, or other file).
struct LocalFolderEntry: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case folder
        case audio
        case playlist
        case other
    }

    var id: String { url.standardizedFileURL.path }
    let url: URL
    let name: String
    let kind: Kind
    let size: Int64
    let modifiedDate: Date?

    var systemImage: String {
        switch kind {
        case .folder: return "folder.fill"
        case .audio: return "music.note"
        case .playlist: return "music.note.list"
        case .other: return "doc"
        }
    }

    var isDirectory: Bool { kind == .folder }
}

/// Finder-style browser over a user-selected Mac folder for File Manager.
@MainActor
final class LocalFolderBrowserStore: ObservableObject {
    @Published private(set) var currentFolder: URL
    @Published private(set) var entries: [LocalFolderEntry] = []
    @Published var searchText = ""
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    private let fileManager = FileManager.default

    static var defaultMusicFolder: URL {
        fileManagerURL(for: .musicDirectory) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")
    }

    init(folder: URL? = nil) {
        let resolved = Self.resolveInitialFolder(folder)
        currentFolder = resolved
        refresh()
    }

    var displayedEntries: [LocalFolderEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [LocalFolderEntry]
        if query.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var selectedEntries: [LocalFolderEntry] {
        displayedEntries.filter { selectedIDs.contains($0.id) }
    }

    var selectedFileURLs: [URL] {
        selectedEntries.filter { !$0.isDirectory }.map(\.url)
    }

    var selectedAudioURLs: [URL] {
        selectedEntries.filter { $0.kind == .audio || $0.kind == .playlist }.map(\.url)
    }

    var canNavigateUp: Bool {
        currentFolder.standardizedFileURL.path != "/"
            && currentFolder.deletingLastPathComponent().path != currentFolder.path
    }

    var breadcrumbPath: String {
        currentFolder.path
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        lastError = nil
        selectedIDs.removeAll()

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: currentFolder,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )
            entries = urls.compactMap(makeEntry(from:))
        } catch {
            entries = []
            lastError = error.localizedDescription
        }
    }

    func navigate(to folder: URL) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            lastError = "Folder not found: \(folder.path)"
            return
        }
        currentFolder = folder.standardizedFileURL
        searchText = ""
        refresh()
    }

    func navigateUp() {
        guard canNavigateUp else { return }
        navigate(to: currentFolder.deletingLastPathComponent())
    }

    func open(_ entry: LocalFolderEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
    }

    func revealInFinder(_ entry: LocalFolderEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder"
        panel.message = "Browse this folder in File Manager."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = currentFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        navigate(to: url)
    }

    func jumpToMusicFolder() {
        let music = Self.defaultMusicFolder
        try? fileManager.createDirectory(at: music, withIntermediateDirectories: true)
        navigate(to: music)
    }

    func selectAllDisplayed() {
        selectedIDs = Set(displayedEntries.map(\.id))
    }

    func deselectAll() {
        selectedIDs.removeAll()
    }

    // MARK: - Private

    private static func resolveInitialFolder(_ folder: URL?) -> URL {
        if let folder {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return folder.standardizedFileURL
            }
        }
        let music = defaultMusicFolder
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        return music.standardizedFileURL
    }

    private static func fileManagerURL(for directory: FileManager.SearchPathDirectory) -> URL? {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
    }

    private func makeEntry(from url: URL) -> LocalFolderEntry? {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey,
            .nameKey
        ])
        if values?.isHidden == true { return nil }

        let isDirectory = values?.isDirectory == true
        let ext = url.pathExtension.lowercased()
        let kind: LocalFolderEntry.Kind
        if isDirectory {
            kind = .folder
        } else if MusicScanner.supportedAudioExtensions.contains(ext)
            || MusicScanner.knownUnsupportedExtensions.contains(ext) {
            kind = .audio
        } else if MusicScanner.supportedPlaylistExtensions.contains(ext) {
            kind = .playlist
        } else {
            kind = .other
        }

        return LocalFolderEntry(
            url: url.standardizedFileURL,
            name: values?.name ?? url.lastPathComponent,
            kind: kind,
            size: Int64(values?.fileSize ?? 0),
            modifiedDate: values?.contentModificationDate
        )
    }
}
