import Foundation

enum GarminVolumeScanner {
    static func scanMountedVolumes() -> [GarminDevice] {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumeURLs = try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .volumeNameKey, .isWritableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return volumeURLs.compactMap { volumeURL in
            guard isGarminCandidate(volumeURL) else { return nil }
            let name = volumeURL.lastPathComponent
            return GarminDevice(
                id: "volume-\(volumeURL.path)",
                name: name,
                volumeURL: volumeURL,
                suggestedMusicFolderURL: suggestedMusicFolder(for: volumeURL),
                kind: .mountedVolume
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func isGarminCandidate(_ volumeURL: URL) -> Bool {
        let name = volumeURL.lastPathComponent.lowercased()
        if ["garmin", "fenix", "forerunner", "venu", "epix", "instinct"].contains(where: { name.contains($0) }) {
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

enum DestinationValidator {
    static func validate(_ url: URL) throws -> DestinationValidationResult {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && !isDirectory.boolValue {
            throw AppError.destinationIsNotDirectory(url.path)
        }

        if !exists {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        var messages = ["Destination exists or was created: \(url.path)"]
        var warnings: [String] = []

        do {
            try FileManager.default.verifyWritableDirectory(url)
            messages.append("Destination is writable.")
        } catch {
            throw AppError.destinationNotWritable(url.path, error.localizedDescription)
        }

        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage
        if let available {
            messages.append("Available capacity: \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)).")
            if available < 100_000_000 {
                warnings.append("Destination has less than 100 MB free.")
            }
        } else {
            warnings.append("Could not determine destination free space.")
        }

        let path = url.path.lowercased()
        if !path.contains("garmin") && !path.contains("music") {
            warnings.append("Destination path does not look Garmin/music-specific. Verify before syncing.")
        }

        return DestinationValidationResult(availableCapacity: available, warnings: warnings, messages: messages + warnings)
    }
}

extension FileManager {
    func verifyWritableDirectory(_ url: URL) throws {
        let probeURL = url.appendingPathComponent(".garmin-music-manager-write-test-\(UUID().uuidString)")
        try "write-test".write(to: probeURL, atomically: true, encoding: .utf8)
        try removeItem(at: probeURL)
    }
}

enum ExperimentalMTPBackend {
    static var isAvailable: Bool {
        CommandRunner.isAvailable("mtp-detect") && CommandRunner.isAvailable("mtp-files") && CommandRunner.isAvailable("mtp-sendfile")
    }

    static var statusText: String {
        let required = ["mtp-detect", "mtp-files", "mtp-sendfile"]
        let missing = required.filter { !CommandRunner.isAvailable($0) }
        if missing.isEmpty { return "libmtp tools found" }
        return "Missing: \(missing.joined(separator: ", "))"
    }

    static func detectDeviceSummary() throws -> String {
        guard isAvailable else { throw AppError.mtpUnavailable(statusText) }
        let result = try CommandRunner.run("mtp-detect", arguments: [], timeoutSeconds: 20)
        return result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func listFilesSummary() throws -> String {
        guard isAvailable else { throw AppError.mtpUnavailable(statusText) }
        let result = try CommandRunner.run("mtp-files", arguments: [], timeoutSeconds: 30)
        return result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sendFile(_ sourceURL: URL, remoteFileName: String) throws -> ShellCommandResult {
        guard isAvailable else { throw AppError.mtpUnavailable(statusText) }
        return try CommandRunner.run(
            "mtp-sendfile",
            arguments: [sourceURL.path, remoteFileName],
            timeoutSeconds: 240
        )
    }
}
