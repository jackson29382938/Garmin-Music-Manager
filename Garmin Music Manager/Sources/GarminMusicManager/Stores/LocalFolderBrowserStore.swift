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

struct LocalPlace: Identifiable, Hashable {
    var id: String { url.path }
    let title: String
    let url: URL
    let systemImage: String
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
    @Published var showHiddenFiles = false
    @Published var recursiveSearch = false
    @Published var sort: LocalFileSort = .name
    @Published var viewMode: LocalViewMode = .list
    @Published var pathDraft = ""
    @Published var favoritePaths: [String] = []

    private let fileManager = FileManager.default

    static var defaultMusicFolder: URL {
        fileManagerURL(for: .musicDirectory) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")
    }

    init(folder: URL? = nil) {
        let resolved = Self.resolveInitialFolder(folder)
        currentFolder = resolved
        pathDraft = resolved.path
        refresh()
    }

    var displayedEntries: [LocalFolderEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var filtered: [LocalFolderEntry]
        if query.isEmpty {
            filtered = entries
        } else if recursiveSearch {
            filtered = recursiveSearchEntries(matching: query)
        } else {
            filtered = entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return sortEntries(filtered)
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

    var standardPlaces: [LocalPlace] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var places: [LocalPlace] = [
            LocalPlace(title: "Music", url: Self.defaultMusicFolder, systemImage: "music.note"),
            LocalPlace(title: "Home", url: home, systemImage: "house"),
        ]
        if let desktop = Self.fileManagerURL(for: .desktopDirectory) {
            places.append(LocalPlace(title: "Desktop", url: desktop, systemImage: "desktopcomputer"))
        }
        if let downloads = Self.fileManagerURL(for: .downloadsDirectory) {
            places.append(LocalPlace(title: "Downloads", url: downloads, systemImage: "arrow.down.circle"))
        }
        if let documents = Self.fileManagerURL(for: .documentDirectory) {
            places.append(LocalPlace(title: "Documents", url: documents, systemImage: "doc"))
        }
        for path in favoritePaths {
            let url = URL(fileURLWithPath: path)
            places.append(LocalPlace(title: url.lastPathComponent, url: url, systemImage: "star.fill"))
        }
        return places
    }

    func applySettings(_ settings: LibrarySettings) {
        showHiddenFiles = settings.fileManagerShowHiddenFiles
        recursiveSearch = settings.fileManagerRecursiveSearch
        favoritePaths = settings.fileManagerFavoritePaths
        if let mode = LocalViewMode(rawValue: settings.fileManagerViewMode) {
            viewMode = mode
        }
        refresh()
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        lastError = nil
        selectedIDs.removeAll()
        pathDraft = currentFolder.path

        do {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHiddenFiles {
                options.insert(.skipsHiddenFiles)
            }
            let urls = try fileManager.contentsOfDirectory(
                at: currentFolder,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey],
                options: options
            )
            entries = urls.compactMap { makeEntry(from: $0, allowHidden: showHiddenFiles) }
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
        pathDraft = currentFolder.path
        searchText = ""
        refresh()
    }

    func navigateUp() {
        guard canNavigateUp else { return }
        navigate(to: currentFolder.deletingLastPathComponent())
    }

    func navigateToPathDraft() {
        let trimmed = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        navigate(to: URL(fileURLWithPath: trimmed))
    }

    func open(_ entry: LocalFolderEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            QuickLookPresenter.preview(urls: [entry.url])
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

    func toggleFavoriteCurrentFolder() {
        let path = currentFolder.path
        if let idx = favoritePaths.firstIndex(of: path) {
            favoritePaths.remove(at: idx)
        } else {
            favoritePaths.append(path)
        }
    }

    func isFavorite(_ url: URL) -> Bool {
        favoritePaths.contains(url.path)
    }

    @discardableResult
    func createFolder(named name: String) -> URL? {
        do {
            let url = try LocalFileOperations.createFolder(named: name, in: currentFolder)
            refresh()
            selectedIDs = [url.path]
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func renameSelected(to newName: String) -> LocalUndoAction? {
        guard let entry = selectedEntries.first else { return nil }
        do {
            let (_, undo) = try LocalFileOperations.rename(entry.url, to: newName)
            refresh()
            return undo
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func trashSelected() -> LocalUndoAction? {
        let urls = selectedEntries.map(\.url)
        guard !urls.isEmpty else { return nil }
        do {
            let result = try LocalFileOperations.trash(urls)
            refresh()
            return result.undo
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func duplicateSelected() -> Bool {
        let urls = selectedEntries.map(\.url)
        guard !urls.isEmpty else { return false }
        do {
            _ = try LocalFileOperations.duplicate(urls)
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func compressSelected() -> URL? {
        let urls = selectedEntries.map(\.url)
        guard !urls.isEmpty else { return nil }
        do {
            let zip = try LocalFileOperations.compress(urls, into: currentFolder)
            refresh()
            return zip
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func decompressSelected() -> Bool {
        let zips = selectedEntries.filter { $0.url.pathExtension.lowercased() == "zip" }.map(\.url)
        guard !zips.isEmpty else { return false }
        do {
            for zip in zips {
                try LocalFileOperations.decompress(zip, into: currentFolder)
            }
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
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

    private func sortEntries(_ entries: [LocalFolderEntry]) -> [LocalFolderEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            switch sort {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.size != rhs.size { return lhs.size < rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date:
                let ld = lhs.modifiedDate ?? .distantPast
                let rd = rhs.modifiedDate ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .kind:
                if lhs.kind != rhs.kind {
                    return lhs.kind.rawValue.localizedStandardCompare(rhs.kind.rawValue) == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func recursiveSearchEntries(matching query: String) -> [LocalFolderEntry] {
        var results: [LocalFolderEntry] = []
        guard let enumerator = fileManager.enumerator(
            at: currentFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey],
            options: showHiddenFiles ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        for case let url as URL in enumerator {
            guard let entry = makeEntry(from: url, allowHidden: showHiddenFiles),
                  entry.name.localizedCaseInsensitiveContains(query) else { continue }
            results.append(entry)
            if results.count >= 500 { break }
        }
        return results
    }

    private func makeEntry(from url: URL, allowHidden: Bool) -> LocalFolderEntry? {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey,
            .nameKey
        ])
        if !allowHidden, values?.isHidden == true { return nil }

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
