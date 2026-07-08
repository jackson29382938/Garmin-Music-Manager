import Foundation

final class DeviceContentService {
    private let fileManager = FileManager.default
    private let audioExtensions = MusicScanner.supportedAudioExtensions

    func listAudioFiles(in destination: URL, recursive: Bool = true) -> [DeviceAudioFile] {
        var results: [DeviceAudioFile] = []

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: destination,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            for case let url as URL in enumerator {
                guard isAudioFile(url) else { continue }
                if let file = makeDeviceFile(from: url) {
                    results.append(file)
                }
            }
        } else {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            for url in contents where isAudioFile(url) {
                if let file = makeDeviceFile(from: url) {
                    results.append(file)
                }
            }
        }

        return results.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    func storageInfo(for destination: URL) -> StorageInfo {
        let files = listAudioFiles(in: destination)
        let audioBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }

        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]

        var total: Int64?
        var available: Int64?

        if let values = try? destination.resourceValues(forKeys: keys) {
            total = values.volumeTotalCapacity.map { Int64($0) }
            available = values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
        }

        if total == nil {
            if let attrs = try? fileManager.attributesOfFileSystem(forPath: destination.path) {
                total = (attrs[.systemSize] as? NSNumber)?.int64Value
                available = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            }
        }

        return StorageInfo(
            totalCapacity: total,
            availableCapacity: available,
            usedByAudioFiles: audioBytes,
            audioFileCount: files.count
        )
    }

    func deleteFiles(at urls: [URL]) throws -> Int {
        var deleted = 0
        for url in urls {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                deleted += 1
            }
        }
        return deleted
    }

    func markDuplicates(tracks: [AudioTrack], destination: URL, playlistName: String) -> [AudioTrack] {
        let cleanName = FileNameSanitizer.sanitizeFileName(playlistName)
        let syncFolder = destination.appendingPathComponent(cleanName, isDirectory: true)
        let deviceFiles = listAudioFiles(in: destination)

        var fingerprintIndex = Set<String>()
        for file in deviceFiles {
            fingerprintIndex.insert("name|\(file.fileName.lowercased())|\(file.byteCount)")
        }

        // Also index files under the playlist subfolder by relative path presence.
        var syncFolderNames = Set<String>()
        if fileManager.fileExists(atPath: syncFolder.path) {
            for file in listAudioFiles(in: syncFolder) {
                syncFolderNames.insert(file.fileName.lowercased())
                fingerprintIndex.insert("name|\(file.fileName.lowercased())|\(file.byteCount)")
            }
        }

        return tracks.map { track in
            var updated = track
            let fingerprints = TrackMatching.trackFingerprintKeys(for: track)
            let byFingerprint = fingerprints.contains(where: { fingerprintIndex.contains($0) })
            let bySyncFolder = syncFolderNames.contains(FileNameSanitizer.safeFileName(for: track).lowercased())
                || syncFolderNames.contains(track.fileName.lowercased())
            updated.isDuplicateOnDevice = byFingerprint || bySyncFolder
            return updated
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    private func makeDeviceFile(from url: URL) -> DeviceAudioFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        return DeviceAudioFile(
            id: url.path,
            url: url,
            fileName: url.lastPathComponent,
            byteCount: Int64(values.fileSize ?? 0),
            modifiedDate: values.contentModificationDate
        )
    }
}
