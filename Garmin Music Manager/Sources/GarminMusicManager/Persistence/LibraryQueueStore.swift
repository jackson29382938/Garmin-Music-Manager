import Foundation

/// Persists the Mac library queue (paths + selection) across launches.
final class LibraryQueueStore {
    private let defaults: UserDefaults
    private let key = "macLibraryQueue.v1"

    struct Entry: Codable, Hashable {
        var path: String
        var isSelected: Bool
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    func save(tracks: [AudioTrack]) {
        let entries = tracks.map {
            Entry(path: $0.url.standardizedFileURL.path, isSelected: $0.isSelected)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Resolves saved paths that still exist on disk into import URLs + selection map.
    func restoreExisting() -> (urls: [URL], selection: [String: Bool]) {
        var urls: [URL] = []
        var selection: [String: Bool] = [:]
        let fileManager = FileManager.default
        for entry in load() {
            let url = URL(fileURLWithPath: entry.path)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let standardized = url.standardizedFileURL
            urls.append(standardized)
            selection[standardized.path] = entry.isSelected
        }
        return (urls, selection)
    }
}
