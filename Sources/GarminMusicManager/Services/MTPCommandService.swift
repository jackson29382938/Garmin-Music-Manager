import Foundation

struct MTPDependencyStatus: Equatable {
    let homebrewURL: URL?
    let mtpDetectURL: URL?
    let mtpSendFileURL: URL?
    let mtpSendTrackURL: URL?

    var isReady: Bool {
        mtpDetectURL != nil && (mtpSendFileURL != nil || mtpSendTrackURL != nil)
    }

    var message: String {
        if isReady { return "MTP support ready (libmtp installed)." }
        if homebrewURL == nil { return "Homebrew and libmtp are not installed." }
        if mtpDetectURL == nil { return "Homebrew is installed, but mtp-detect is missing." }
        return "Homebrew is installed, but libmtp transfer tools are missing."
    }
}

struct MTPDeviceContents {
    let files: [DeviceAudioFile]
    let playlists: [DevicePlaylist]
    let deviceName: String?
    let diagnosticMessage: String?
    let fileIDByName: [String: String]

    init(
        files: [DeviceAudioFile],
        playlists: [DevicePlaylist],
        deviceName: String?,
        diagnosticMessage: String?,
        fileIDByName: [String: String] = [:]
    ) {
        self.files = files
        self.playlists = playlists
        self.deviceName = deviceName
        self.diagnosticMessage = diagnosticMessage
        self.fileIDByName = fileIDByName
    }

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    var storageInfo: StorageInfo {
        StorageInfo(
            totalCapacity: nil,
            availableCapacity: nil,
            usedByAudioFiles: totalBytes,
            audioFileCount: files.count
        )
    }
}

final class MTPCommandService {
    private let fileManager = FileManager.default
    private let accessQueue = DispatchQueue(label: "com.garminmusicmanager.mtp-access", qos: .userInitiated)

    private static let mtpEnvironment = """
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    export LC_CTYPE=en_US.UTF-8
    """

    func dependencyStatus() -> MTPDependencyStatus {
        MTPDependencyStatus(
            homebrewURL: executableURL(named: "brew"),
            mtpDetectURL: executableURL(named: "mtp-detect"),
            mtpSendFileURL: executableURL(named: "mtp-sendfile"),
            mtpSendTrackURL: executableURL(named: "mtp-sendtr")
        )
    }

    func installDependencies(progress: @escaping @Sendable (String) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            let script = """
            \(Self.mtpEnvironment)
            set -euo pipefail
            export NONINTERACTIVE=1
            export HOMEBREW_NO_ENV_HINTS=1

            if ! command -v brew >/dev/null 2>&1; then
              echo "Installing Homebrew..."
              /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
              if [ -x /opt/homebrew/bin/brew ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
              elif [ -x /usr/local/bin/brew ]; then
                eval "$(/usr/local/bin/brew shellenv)"
              fi
            else
              echo "Homebrew already installed."
            fi

            if ! command -v mtp-detect >/dev/null 2>&1 || { ! command -v mtp-sendfile >/dev/null 2>&1 && ! command -v mtp-sendtr >/dev/null 2>&1; }; then
              echo "Installing libmtp..."
              brew install libmtp
            else
              echo "libmtp already installed."
            fi
            echo "MTP dependencies ready."
            """
            try self.runShell(script, timeout: 1800, surfaceOutput: true) { line in
                progress(line)
            }
        }.value
    }

    func sync(
        tracks: [AudioTrack],
        playlistName: String,
        settings: SyncSettings,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> SyncResult {
        try await performExclusive {
            let status = self.dependencyStatus()
            guard status.mtpSendFileURL != nil || status.mtpSendTrackURL != nil else {
                throw MTPError.dependenciesMissing(status.message)
            }

            let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
            let stagingRoot = self.fileManager.temporaryDirectory
                .appendingPathComponent("GarminMusicManager-MTP", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let targetFolder = stagingRoot.appendingPathComponent(cleanPlaylistName, isDirectory: true)
            try self.fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
            defer { try? self.fileManager.removeItem(at: stagingRoot) }

            var audioFiles: [(local: URL, remotePath: String, track: AudioTrack)] = []
            for track in tracks {
                let targetURL = self.resolveTargetURL(for: track, in: targetFolder, settings: settings)
                try self.fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if self.fileManager.fileExists(atPath: targetURL.path) {
                    try self.fileManager.removeItem(at: targetURL)
                }
                try self.fileManager.copyItem(at: track.url, to: targetURL)
                let relativePath = targetURL.path.replacingOccurrences(of: targetFolder.path + "/", with: "")
                let remotePath = "Music/\(cleanPlaylistName)/\(relativePath)"
                audioFiles.append((targetURL, remotePath, track))
            }

            var copied = 0
            for (index, file) in audioFiles.enumerated() {
                try Task.checkCancellation()
                let fraction = Double(index) / Double(max(audioFiles.count, 1))
                let pathCandidates = self.remotePathCandidates(
                    desiredRemotePath: file.remotePath,
                    fileName: file.local.lastPathComponent,
                    preferFlatTransfer: status.mtpSendTrackURL != nil
                )

                var sentRemotePath: String?
                var lastError: Error?

                for (candidateIndex, remotePath) in pathCandidates.enumerated() {
                    try Task.checkCancellation()
                    let retryPrefix = candidateIndex == 0 ? "Sending" : "Retrying"
                    progress(fraction, "\(retryPrefix) to Garmin MTP: \(remotePath)")

                    do {
                        if let mtpSendTrackURL = status.mtpSendTrackURL {
                            try self.sendTrackWithRetry(
                                mtpSendTrackURL: mtpSendTrackURL,
                                localURL: file.local,
                                remotePath: remotePath,
                                track: file.track,
                                playlistName: cleanPlaylistName
                            )
                        } else if let mtpSendFileURL = status.mtpSendFileURL {
                            try self.sendFileWithRetry(
                                mtpSendFileURL: mtpSendFileURL,
                                localURL: file.local,
                                remotePath: remotePath
                            )
                        }
                        sentRemotePath = remotePath
                        break
                    } catch {
                        lastError = error
                    }
                }

                if sentRemotePath == nil {
                    throw lastError ?? MTPError.commandFailed("MTP transfer failed.")
                }

                copied += 1
                progress(
                    Double(index + 1) / Double(max(audioFiles.count, 1)),
                    "Sent \(sentRemotePath ?? file.local.lastPathComponent)"
                )
            }

            // Garmin music watches only accept audio files over MTP. Any non-audio
            // file (including an .m3u8 playlist) is rejected by the device, so we do
            // not attempt to upload one. The watch auto-indexes the copied audio, and
            // the app groups it under the folder name as a playlist when browsing.
            if settings.writePlaylist {
                progress(1, "Note: Garmin watches don't accept .m3u8 files over USB. \(copied) song(s) copied to Music › \(cleanPlaylistName); group them into a playlist in Garmin Connect if desired.")
            }

            return SyncResult(
                copiedCount: copied,
                skippedCount: 0,
                replacedCount: 0,
                playlistURL: targetFolder.appendingPathComponent("\(cleanPlaylistName).m3u8"),
                targetFolder: URL(fileURLWithPath: "Garmin MTP / Music / \(cleanPlaylistName)")
            )
        }
    }

    func listDeviceMusicFiles(
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MTPDeviceContents {
        try await performExclusive {
            progress("Reading Garmin library over MTP…")

            if let contents = try? self.readLibraryInSingleSession(progress: progress),
               !contents.files.isEmpty {
                return contents
            }

            if let contents = try? self.readTrackLibraryInSingleSession(progress: progress),
               !contents.files.isEmpty {
                return contents
            }

            if let contents = try? self.readTrackLibraryInSingleSession(progress: progress) {
                return contents
            }

            if let contents = try? self.readLibraryInSingleSession(progress: progress) {
                return contents
            }

            throw MTPError.commandFailed("Could not read music from the Garmin. Wake/unlock the watch, use a data USB cable, and try Refresh.")
        }
    }

    func downloadFiles(
        _ files: [DeviceAudioFile],
        to destinationFolder: URL,
        fileIDIndex: [String: String] = [:],
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Int {
        try await performExclusive {
            guard let mtpGetFileURL = self.executableURL(named: "mtp-getfile") else {
                throw MTPError.dependenciesMissing("mtp-getfile is not available. Reinstall MTP support.")
            }

            var fileIDIndex = fileIDIndex
            if files.contains(where: { $0.mtpFileID == nil }) {
                fileIDIndex = try self.refreshFileIDIndex(merging: fileIDIndex)
            }

            var copied = 0
            for file in files {
                try Task.checkCancellation()
                guard let objectID = self.resolveDownloadObjectID(for: file, fileIDIndex: fileIDIndex) else {
                    throw MTPError.commandFailed("Could not resolve a Garmin object ID for \(file.fileName). Refresh the library and try again.")
                }

                let localURL = FileNameSanitizer.uniqueURL(
                    in: destinationFolder,
                    preferredFileName: FileNameSanitizer.sanitizeFileName(file.fileName, fallback: "Garmin Track")
                )
                progress("Copying \(file.fileName) from Garmin…")

                try self.runMTPTransferWithRetry {
                    let command = """
                    \(Self.mtpEnvironment)
                    \(self.shellQuoted(mtpGetFileURL.path)) \(self.shellQuoted(objectID)) \(self.shellQuoted(localURL.path)) 2>&1
                    """
                    try self.runShell(command, timeout: 600, surfaceOutput: false) { _ in }
                }

                guard self.fileManager.fileExists(atPath: localURL.path) else {
                    throw MTPError.commandFailed("Copy finished but \(localURL.lastPathComponent) was not created on disk.")
                }

                let byteCount = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                guard byteCount > 0 else {
                    try? self.fileManager.removeItem(at: localURL)
                    throw MTPError.commandFailed("Copy of \(file.fileName) produced an empty file. The watch may be busy — wait a moment and try again.")
                }

                copied += 1
            }
            return copied
        }
    }

    func deleteFiles(
        _ files: [DeviceAudioFile],
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Int {
        try await performExclusive {
            guard let mtpDeleteFileURL = self.executableURL(named: "mtp-delfile") else {
                throw MTPError.dependenciesMissing("mtp-delfile is not available. Reinstall MTP support.")
            }

            var deleted = 0
            for file in files {
                try Task.checkCancellation()
                guard let objectID = file.mtpFileID ?? file.mtpTrackID else { continue }
                progress("Deleting \(file.fileName) from Garmin…")
                try self.runMTPTransferWithRetry {
                    let command = """
                    \(Self.mtpEnvironment)
                    \(self.shellQuoted(mtpDeleteFileURL.path)) -n \(self.shellQuoted(objectID)) 2>&1
                    """
                    try self.runShell(command, timeout: 120, surfaceOutput: false) { _ in }
                }
                deleted += 1
            }
            return deleted
        }
    }

    func buildPreview(tracks: [AudioTrack], playlistName: String, settings: SyncSettings) -> SyncPreview {
        let cleanPlaylistName = FileNameSanitizer.sanitizeFileName(playlistName)
        var items: [SyncPreviewItem] = []
        var totalBytes: Int64 = 0
        let virtualRoot = URL(fileURLWithPath: "Garmin MTP/Music/\(cleanPlaylistName)")
        for track in tracks {
            let targetURL = resolveTargetURL(for: track, in: virtualRoot, settings: settings)
            items.append(SyncPreviewItem(track: track, action: .copy, targetPath: targetURL.path))
            totalBytes += track.byteCount
        }
        return SyncPreview(items: items, totalBytesToCopy: totalBytes)
    }

    private struct MTPRawEntry {
        var fileID: String
        var filename: String
        var fileSize: Int64
        var parentID: String?
        var storageID: String?
        var filetype: String?

        var isFolder: Bool {
            let type = filetype?.lowercased() ?? ""
            return type.contains("association") || type.contains("directory") || type.contains("folder")
        }

        var isAudio: Bool {
            let ext = (filename as NSString).pathExtension.lowercased()
            let type = filetype?.lowercased() ?? ""
            let audioTypeHints = ["audio", "mp3", "mp4", "aac", "wav", "mpeg"]
            return MusicScanner.supportedAudioExtensions.contains(ext)
                || audioTypeHints.contains(where: { type.contains($0) })
        }

        var isPlaylist: Bool {
            let ext = (filename as NSString).pathExtension.lowercased()
            return MusicScanner.supportedPlaylistExtensions.contains(ext)
        }
    }

    private struct MTPTrackEntry {
        var trackID: String
        var title: String?
        var artist: String?
        var album: String?
        var originalFileName: String?
        var fileSize: Int64
        var filetype: String?

        var displayFileName: String {
            let rawName = originalFileName?.nilIfEmpty
                ?? title?.nilIfEmpty
                ?? "Track \(trackID)"
            let ext = (rawName as NSString).pathExtension
            guard ext.isEmpty, let preferredExtension else { return rawName }
            return "\(rawName).\(preferredExtension)"
        }

        private var preferredExtension: String? {
            let type = filetype?.lowercased() ?? ""
            if type.contains("mp3") || type.contains("mpeg") { return "mp3" }
            if type.contains("aac") { return "aac" }
            if type.contains("mp4") { return "m4a" }
            if type.contains("wav") { return "wav" }
            return nil
        }
    }

    private struct MTPPlaylistEntry {
        var playlistID: String
        var name: String
        var trackReferences: [(trackID: String, displayName: String)]
    }

    private func performExclusive<T: Sendable>(
        _ operation: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            accessQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readLibraryInSingleSession(
        progress: @escaping @Sendable (String) -> Void
    ) throws -> MTPDeviceContents {
        guard let mtpConnectURL = executableURL(named: "mtp-connect"),
              let mtpFilesURL = executableURL(named: "mtp-files") else {
            throw MTPError.dependenciesMissing("mtp-files is not available.")
        }

        let commands: [String] = {
            var items = [shellQuoted(mtpFilesURL.path)]
            if let playlistsURL = executableURL(named: "mtp-playlists") {
                items.append(shellQuoted(playlistsURL.path))
            }
            return items
        }()

        let output = try runConnectedCommands(connectURL: mtpConnectURL, commands: commands, timeout: 180)
        try Self.validateMTPOutput(output, allowNoPlaylists: true)

        let entries = parseMTPFilesystem(output)
        let audioFiles = buildAudioFiles(from: entries)
        let fileIDByName = fileIDIndex(for: audioFiles)
        let playlists = buildSmartPlaylists(
            mtpPlaylists: (try? listDevicePlaylists(from: output, knownFiles: audioFiles)) ?? [],
            audioFiles: audioFiles
        )

        return MTPDeviceContents(
            files: audioFiles,
            playlists: playlists,
            deviceName: parseMTPDeviceName(output),
            diagnosticMessage: diagnosticMessage(
                fileCount: audioFiles.count,
                playlistCount: playlists.count,
                rawObjectCount: entries.count
            ),
            fileIDByName: fileIDByName
        )
    }

    private func readTrackLibraryInSingleSession(
        progress: @escaping @Sendable (String) -> Void
    ) throws -> MTPDeviceContents {
        guard let mtpConnectURL = executableURL(named: "mtp-connect"),
              let mtpTracksURL = executableURL(named: "mtp-tracks") else {
            throw MTPError.dependenciesMissing("mtp-tracks is not available.")
        }

        progress("Reading Garmin track index over MTP…")
        var commands = [shellQuoted(mtpTracksURL.path)]
        if let playlistsURL = executableURL(named: "mtp-playlists") {
            commands.append(shellQuoted(playlistsURL.path))
        }

        let output = try runConnectedCommands(connectURL: mtpConnectURL, commands: commands, timeout: 180)
        try Self.validateMTPOutput(output, allowNoPlaylists: true)

        let trackEntries = parseMTPTracks(output)
        var files = trackEntries.map { track in
            DeviceAudioFile(
                id: "mtp-track:\(track.trackID)",
                url: URL(string: "mtp://track/\(track.trackID)") ?? URL(fileURLWithPath: track.displayFileName),
                fileName: track.displayFileName,
                byteCount: track.fileSize,
                modifiedDate: nil,
                folderName: track.album?.nilIfEmpty,
                mtpFileID: nil,
                mtpTrackID: track.trackID
            )
        }
        files.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }

        let playlists = buildSmartPlaylists(
            mtpPlaylists: (try? listDevicePlaylists(from: output, knownFiles: files)) ?? [],
            audioFiles: files
        )

        return MTPDeviceContents(
            files: files,
            playlists: playlists,
            deviceName: parseMTPDeviceName(output),
            diagnosticMessage: diagnosticMessage(
                fileCount: files.count,
                playlistCount: playlists.count,
                rawObjectCount: trackEntries.count
            ),
            fileIDByName: fileIDIndex(for: files)
        )
    }

    private func runConnectedCommands(connectURL: URL, commands: [String], timeout: TimeInterval) throws -> String {
        let commandLine = """
        \(Self.mtpEnvironment)
        \(shellQuoted(connectURL.path)) \(commands.joined(separator: " ")) 2>&1
        """
        return try runShellCapturing(commandLine, timeout: timeout)
    }

    private func buildAudioFiles(from entries: [MTPRawEntry]) -> [DeviceAudioFile] {
        let foldersByID = Dictionary(uniqueKeysWithValues: entries.filter(\.isFolder).map { ($0.fileID, $0.filename) })
        let parentPairs: [(String, String)] = entries.compactMap { entry in
            guard let parentID = entry.parentID else { return nil }
            return (entry.fileID, parentID)
        }
        let parentByID = Dictionary(uniqueKeysWithValues: parentPairs)

        func resolveFolderName(for fileID: String) -> String? {
            guard let parentID = parentByID[fileID], let parentName = foldersByID[parentID] else { return nil }
            if parentName.localizedCaseInsensitiveContains("music") {
                if let grandparentID = parentByID[parentID],
                   let grandparentName = foldersByID[grandparentID],
                   !grandparentName.localizedCaseInsensitiveContains("music") {
                    return grandparentName
                }
                return nil
            }
            return parentName
        }

        let audioFiles = entries.compactMap { entry -> DeviceAudioFile? in
            guard !entry.isFolder, entry.isAudio else { return nil }
            return DeviceAudioFile(
                id: "mtp:\(entry.fileID)",
                url: URL(string: "mtp://file/\(entry.fileID)") ?? URL(fileURLWithPath: entry.filename),
                fileName: entry.filename,
                byteCount: entry.fileSize,
                modifiedDate: nil,
                folderName: resolveFolderName(for: entry.fileID),
                mtpFileID: entry.fileID,
                mtpTrackID: nil
            )
        }

        return audioFiles.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    private func fileIDIndex(for files: [DeviceAudioFile]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: files.compactMap { file in
            guard let id = file.mtpFileID ?? file.mtpTrackID else { return nil }
            return (file.fileName.lowercased(), id)
        })
    }

    private func buildSmartPlaylists(
        mtpPlaylists: [DevicePlaylist],
        audioFiles: [DeviceAudioFile]
    ) -> [DevicePlaylist] {
        var playlists = mtpPlaylists.filter { $0.trackCount > 0 }
        var coveredTrackNames = Set(playlists.flatMap(\.trackFileNames).map { $0.lowercased() })

        let byAlbum = Dictionary(grouping: audioFiles) { file in
            file.folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        for (album, albumFiles) in byAlbum.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            guard albumFiles.count >= 2, !album.isEmpty else { continue }
            let trackNames = albumFiles.map(\.fileName)
            let normalizedTracks = Set(trackNames.map { $0.lowercased() })
            if normalizedTracks.isSubset(of: coveredTrackNames) { continue }
            if isPerTrackAlbumName(album, tracks: trackNames) { continue }

            playlists.append(DevicePlaylist(
                id: "album:\(album)",
                name: album,
                trackFileNames: trackNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                source: .folder
            ))
            coveredTrackNames.formUnion(normalizedTracks)
        }

        let byFolder = Dictionary(grouping: audioFiles) { file in
            file.folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        for (folder, folderFiles) in byFolder.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            guard folderFiles.count >= 2, !folder.isEmpty else { continue }
            let trackNames = folderFiles.map(\.fileName)
            if isPerTrackFolderName(folder, tracks: trackNames) { continue }

            let normalizedTracks = Set(trackNames.map { $0.lowercased() })
            if normalizedTracks.isSubset(of: coveredTrackNames) { continue }

            playlists.append(DevicePlaylist(
                id: "folder:\(folder)",
                name: folder,
                trackFileNames: trackNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                source: .folder
            ))
            coveredTrackNames.formUnion(normalizedTracks)
        }

        var seenNames: Set<String> = []
        return playlists
            .filter { playlist in
                let key = playlist.name.lowercased()
                guard !seenNames.contains(key) else { return false }
                seenNames.insert(key)
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isPerTrackFolderName(_ folder: String, tracks: [String]) -> Bool {
        guard tracks.count == 1, let track = tracks.first else { return false }
        let stem = (track as NSString).deletingPathExtension
        let normalizedFolder = folder.lowercased()
        let normalizedStem = stem.lowercased()
        return normalizedFolder == normalizedStem
            || normalizedFolder.contains(normalizedStem)
            || normalizedStem.contains(normalizedFolder)
    }

    private func isPerTrackAlbumName(_ album: String, tracks: [String]) -> Bool {
        guard tracks.count == 1, let track = tracks.first else { return false }
        let stem = (track as NSString).deletingPathExtension
        return album.localizedCaseInsensitiveCompare(stem) == .orderedSame
    }

    private func refreshFileIDIndex(merging existing: [String: String]) throws -> [String: String] {
        guard let mtpConnectURL = executableURL(named: "mtp-connect"),
              let mtpFilesURL = executableURL(named: "mtp-files") else {
            return existing
        }

        let output = try runConnectedCommands(
            connectURL: mtpConnectURL,
            commands: [shellQuoted(mtpFilesURL.path)],
            timeout: 180
        )
        try Self.validateMTPOutput(output, allowNoPlaylists: true)

        var merged = existing
        for file in buildAudioFiles(from: parseMTPFilesystem(output)) {
            if let id = file.mtpFileID {
                merged[file.fileName.lowercased()] = id
            }
        }
        return merged
    }

    private func resolveDownloadObjectID(for file: DeviceAudioFile, fileIDIndex: [String: String]) -> String? {
        if let mtpFileID = file.mtpFileID { return mtpFileID }
        if let indexed = fileIDIndex[file.fileName.lowercased()] { return indexed }
        if let mtpTrackID = file.mtpTrackID { return mtpTrackID }
        return nil
    }

    private func listDevicePlaylists(from output: String, knownFiles: [DeviceAudioFile]) throws -> [DevicePlaylist] {
        try Self.validateMTPOutput(output, allowNoPlaylists: true)
        let playlistEntries = parseMTPPlaylists(output)
        guard !playlistEntries.isEmpty else { return [] }

        let fileNameByMTPID = Dictionary(
            uniqueKeysWithValues: knownFiles.compactMap { file -> (String, String)? in
                let id = file.mtpFileID ?? file.mtpTrackID
                guard let id else { return nil }
                return (id, file.fileName)
            }
        )

        return playlistEntries.map { playlist in
            DevicePlaylist(
                id: "mtp-playlist:\(playlist.playlistID)",
                name: playlist.name,
                trackFileNames: playlist.trackReferences.map { reference in
                    fileNameByMTPID[reference.trackID] ?? reference.displayName
                },
                source: .mtpPlaylist
            )
        }
    }

    private func listDevicePlaylists(knownFiles: [DeviceAudioFile]) throws -> [DevicePlaylist] {
        guard let mtpPlaylistsURL = executableURL(named: "mtp-playlists") else {
            return []
        }

        let output = try runShellCapturing("\(shellQuoted(mtpPlaylistsURL.path)) 2>&1", timeout: 45)
        return try listDevicePlaylists(from: output, knownFiles: knownFiles)
    }

    private func diagnosticMessage(fileCount: Int, playlistCount: Int, rawObjectCount: Int) -> String? {
        if fileCount > 0 || playlistCount > 0 {
            return nil
        }
        if rawObjectCount > 0 {
            return "Garmin responded with \(rawObjectCount) MTP object(s), but none were exposed as supported audio files. Music from streaming providers may be hidden/protected, and local tracks may require unplugging/reconnecting the watch before they appear."
        }
        return "Garmin responded, but did not expose any music files or playlists over MTP."
    }

    private func parseMTPDeviceName(_ output: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Model:") {
                return value(afterColonIn: line)
            }
            if line.hasPrefix("Friendly name:") {
                return value(afterColonIn: line)
            }
            if let range = line.range(of: "Device with name:") {
                let name = line[range.upperBound...]
                    .split(separator: "[", maxSplits: 1)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let name, !name.isEmpty {
                    return name
                }
            }
            if line.hasPrefix("Device "), let range = line.range(of: " is a ") {
                let name = line[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
                if !name.isEmpty {
                    return name
                }
            }
        }
        return nil
    }

    private func parseMTPFilesystem(_ output: String) -> [MTPRawEntry] {
        var entries: [MTPRawEntry] = []
        var currentID: String?
        var currentName: String?
        var currentSize: Int64 = 0
        var currentParentID: String?
        var currentStorageID: String?
        var currentType: String?

        func flush() {
            defer {
                currentID = nil
                currentName = nil
                currentSize = 0
                currentParentID = nil
                currentStorageID = nil
                currentType = nil
            }
            guard let currentID, let currentName, !currentName.isEmpty else { return }
            entries.append(MTPRawEntry(
                fileID: currentID,
                filename: currentName,
                fileSize: currentSize,
                parentID: currentParentID,
                storageID: currentStorageID,
                filetype: currentType
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("File ID:") {
                flush()
                currentID = value(afterColonIn: line)
            } else if line.hasPrefix("Filename:") {
                currentName = value(afterColonIn: line)
            } else if line.hasPrefix("File size") {
                let raw = value(afterColonIn: line) ?? line.replacingOccurrences(of: "File size", with: "").trimmingCharacters(in: .whitespaces)
                let digits = raw.prefix { $0.isNumber }
                currentSize = Int64(digits) ?? 0
            } else if line.hasPrefix("Parent ID:") {
                currentParentID = value(afterColonIn: line)
            } else if line.hasPrefix("Storage ID:") {
                currentStorageID = value(afterColonIn: line)
            } else if line.hasPrefix("Filetype:") {
                currentType = value(afterColonIn: line)
            }
        }
        flush()

        return entries
    }

    private func parseMTPTracks(_ output: String) -> [MTPTrackEntry] {
        var entries: [MTPTrackEntry] = []
        var currentID: String?
        var currentTitle: String?
        var currentArtist: String?
        var currentAlbum: String?
        var currentOriginalFileName: String?
        var currentSize: Int64 = 0
        var currentType: String?

        func flush() {
            defer {
                currentID = nil
                currentTitle = nil
                currentArtist = nil
                currentAlbum = nil
                currentOriginalFileName = nil
                currentSize = 0
                currentType = nil
            }
            guard let currentID else { return }
            entries.append(MTPTrackEntry(
                trackID: currentID,
                title: currentTitle,
                artist: currentArtist,
                album: currentAlbum,
                originalFileName: currentOriginalFileName,
                fileSize: currentSize,
                filetype: currentType
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Track ID:") {
                flush()
                currentID = value(afterColonIn: line)
            } else if line.hasPrefix("Title:") {
                currentTitle = value(afterColonIn: line)
            } else if line.hasPrefix("Artist:") {
                currentArtist = value(afterColonIn: line)
            } else if line.hasPrefix("Album:") {
                currentAlbum = value(afterColonIn: line)
            } else if line.hasPrefix("Origfilename:") {
                currentOriginalFileName = value(afterColonIn: line)
            } else if line.hasPrefix("File size") {
                let raw = value(afterColonIn: line) ?? line.replacingOccurrences(of: "File size", with: "").trimmingCharacters(in: .whitespaces)
                let digits = raw.prefix { $0.isNumber }
                currentSize = Int64(digits) ?? 0
            } else if line.hasPrefix("Filetype:") {
                currentType = value(afterColonIn: line)
            }
        }
        flush()

        return entries
    }

    private func parseMTPPlaylists(_ output: String) -> [MTPPlaylistEntry] {
        var entries: [MTPPlaylistEntry] = []
        var currentID: String?
        var currentName: String?
        var currentTracks: [(trackID: String, displayName: String)] = []

        func flush() {
            defer {
                currentID = nil
                currentName = nil
                currentTracks = []
            }
            guard let currentID, let currentName, !currentName.isEmpty else { return }
            entries.append(MTPPlaylistEntry(
                playlistID: currentID,
                name: currentName,
                trackReferences: currentTracks
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Playlist ID:") {
                flush()
                currentID = value(afterColonIn: line)
            } else if line.hasPrefix("Name:") {
                currentName = value(afterColonIn: line)
            } else if let trackReference = parsePlaylistTrackReference(line) {
                currentTracks.append(trackReference)
            }
        }
        flush()

        return entries
    }

    private func parsePlaylistTrackReference(_ line: String) -> (trackID: String, displayName: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let id = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }

        let rest = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, !rest.localizedCaseInsensitiveContains("INVALID TRACK REFERENCE") else {
            return nil
        }

        return (id, rest)
    }

    private func remotePathCandidates(
        desiredRemotePath: String,
        fileName: String,
        preferFlatTransfer: Bool
    ) -> [String] {
        let candidates: [String]
        if preferFlatTransfer {
            candidates = [
                fileName,
                desiredRemotePath,
                "Music/\(fileName)"
            ]
        } else {
            candidates = [
                desiredRemotePath,
                "Music/\(fileName)",
                fileName
            ]
        }

        var seen: Set<String> = []
        return candidates.filter { candidate in
            seen.insert(candidate).inserted
        }
    }

    private func sendTrackWithRetry(
        mtpSendTrackURL: URL,
        localURL: URL,
        remotePath: String,
        track: AudioTrack,
        playlistName: String
    ) throws {
        try runMTPTransferWithRetry {
            try self.sendTrack(
                mtpSendTrackURL: mtpSendTrackURL,
                localURL: localURL,
                remotePath: remotePath,
                track: track,
                playlistName: playlistName
            )
        }
    }

    private func sendTrack(
        mtpSendTrackURL: URL,
        localURL: URL,
        remotePath: String,
        track: AudioTrack,
        playlistName: String
    ) throws {
        var arguments = ["-q"]
        arguments.append(contentsOf: ["-t", track.title?.nilIfEmpty ?? localURL.deletingPathExtension().lastPathComponent])
        if let artist = track.artist?.nilIfEmpty {
            arguments.append(contentsOf: ["-a", artist])
        }
        arguments.append(contentsOf: ["-l", track.album?.nilIfEmpty ?? playlistName])
        if let durationSeconds = track.durationSeconds, durationSeconds.isFinite {
            arguments.append(contentsOf: ["-d", String(Int(durationSeconds))])
        }
        arguments.append(contentsOf: [localURL.path, remotePath])

        let command = """
        \(Self.mtpEnvironment)
        \(shellQuoted(mtpSendTrackURL.path)) \(arguments.map { shellQuoted($0) }.joined(separator: " ")) 2>&1
        """
        try runShell(command, timeout: 600, surfaceOutput: false) { _ in }
    }

    private func sendFileWithRetry(mtpSendFileURL: URL, localURL: URL, remotePath: String) throws {
        try runMTPTransferWithRetry {
            try self.sendFile(mtpSendFileURL: mtpSendFileURL, localURL: localURL, remotePath: remotePath)
        }
    }

    private func sendFile(mtpSendFileURL: URL, localURL: URL, remotePath: String) throws {
        let command = """
        \(Self.mtpEnvironment)
        \(shellQuoted(mtpSendFileURL.path)) \(shellQuoted(localURL.path)) \(shellQuoted(remotePath)) 2>&1
        """
        try runShell(command, timeout: 600, surfaceOutput: false) { _ in }
    }

    private func runMTPTransferWithRetry(_ operation: () throws -> Void) throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try operation()
                return
            } catch {
                lastError = error
                guard attempt < 3, Self.isTransientMTPError(error) else {
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
        throw lastError ?? MTPError.commandFailed("MTP transfer failed.")
    }

    private func runShellCapturing(_ command: String, timeout: TimeInterval) throws -> String {
        var captured = ""
        try runShell(command, timeout: timeout, surfaceOutput: false) { line in
            captured += line + "\n"
        }
        return captured
    }

    private func value(afterColonIn line: String) -> String? {
        guard let range = line.range(of: ":") else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func runShell(
        _ command: String,
        timeout: TimeInterval,
        surfaceOutput: Bool,
        output: @escaping (String) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8"
        ]) { _, new in new }
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var captured = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            captured += chunk
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                if surfaceOutput || Self.shouldSurfaceMTPLogLine(text) {
                    output(text)
                }
            }
        }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw MTPError.commandFailed("Command timed out.")
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw MTPError.commandFailed(Self.userFacingMTPError(from: captured))
        }
    }

    private static func shouldSurfaceMTPLogLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let suppressedPrefixes = [
            "libmtp version:",
            "MTP extended association type",
            "Your system does not appear to have UTF-8",
            "If you want to have support for diacritics",
            "please switch your locale",
            "Sending file",
            "Sending ",
            "type: ",
            "Error sending file."
        ]
        if suppressedPrefixes.contains(where: { trimmed.hasPrefix($0) || trimmed.contains($0) }) {
            return false
        }
        return true
    }

    private static func validateMTPOutput(_ output: String, allowNoPlaylists: Bool = false) throws {
        let lowerOutput = output.lowercased()
        if allowNoPlaylists && lowerOutput.contains("no playlists.") {
            return
        }
        if lowerOutput.contains("no devices have been found")
            || lowerOutput.contains("no raw devices found")
            || lowerOutput.contains("no devices found")
            || lowerOutput.contains("no devices.") {
            throw MTPError.noDevice
        }

        if outputReportsConnectionFailure(output) {
            throw MTPError.commandFailed(userFacingMTPError(from: output))
        }
    }

    private static func outputReportsConnectionFailure(_ output: String) -> Bool {
        let lowerOutput = output.lowercased()
        return lowerOutput.contains("libusb_claim_interface")
            || lowerOutput.contains("unable to open raw device")
            || lowerOutput.contains("failed to open session")
            || lowerOutput.contains("unable to initialize device")
            || lowerOutput.contains("ptp_error_io")
    }

    private static func userFacingMTPError(from output: String) -> String {
        let lowerOutput = output.lowercased()
        if lowerOutput.contains("libusb_claim_interface")
            || lowerOutput.contains("unable to open raw device")
            || lowerOutput.contains("failed to open session") {
            return "Garmin is visible, but MTP could not open the USB connection. Close Garmin Express or other transfer apps, unplug and reconnect the watch, then try again."
        }
        if lowerOutput.contains("parent folder could not be found") {
            return "The Garmin rejected that folder path. The app will retry with a simpler destination."
        }

        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && shouldSurfaceMTPLogLine(String($0)) }

        if let last = lines.last, !last.isEmpty {
            return last
        }
        return "MTP command failed."
    }

    private static func isTransientMTPError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("could not open the usb connection")
            || message.contains("unable to open raw device")
            || message.contains("failed to open session")
            || message.contains("claim_interface")
    }

    private func resolveTargetURL(for track: AudioTrack, in targetFolder: URL, settings: SyncSettings) -> URL {
        var folder = targetFolder
        switch settings.organizationPolicy {
        case .flat:
            break
        case .byArtist:
            if let artist = track.artist?.nilIfEmpty {
                folder = folder.appendingPathComponent(FileNameSanitizer.sanitizePathComponent(artist), isDirectory: true)
            }
        case .byArtistAlbum:
            for component in track.organizationFolderComponents {
                folder = folder.appendingPathComponent(component, isDirectory: true)
            }
        }
        return folder.appendingPathComponent(FileNameSanitizer.safeFileName(for: track))
    }

    private func executableURL(named executableName: String) -> URL? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        for directory in searchPaths {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

enum MTPError: LocalizedError {
    case noDevice
    case dependenciesMissing(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No Garmin MTP device is responding. Connect the watch with a data-capable USB cable, wake/unlock it, close Garmin Express or other transfer apps, then refresh."
        case .dependenciesMissing(let message):
            return message
        case .commandFailed(let output):
            return output.isEmpty ? "MTP command failed." : output
        }
    }
}
