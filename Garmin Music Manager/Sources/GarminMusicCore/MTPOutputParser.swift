import Foundation

/// Parses **legacy CLI tool text output** (mtp-files / mtp-tracks style).
///
/// The production app path uses direct libmtp via `GarminMTPHelper` and does not
/// call this parser. Kept for unit tests and any offline diagnostics that still
/// feed raw CLI dumps.
public enum MTPOutputParser {
    private static let supportedAudioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "alac"]
    private static let supportedPlaylistExtensions: Set<String> = ["m3u", "m3u8", "pls"]

    public static func makeMusicSnapshot(
        tracksOutput: String?,
        filesOutput: String?,
        playlistsOutput: String?,
        deviceOutput: String? = nil
    ) throws -> DeviceFileSystemSnapshot {
        let joinedOutput = [tracksOutput, filesOutput, playlistsOutput, deviceOutput]
            .compactMap { $0 }
            .joined(separator: "\n")
        try validateMTPOutput(joinedOutput, allowNoPlaylists: true)

        let trackEntries = parseTracks(tracksOutput ?? "")
        let fileEntries = parseFilesystem(filesOutput ?? "")

        var files: [DeviceFile]
        if !trackEntries.isEmpty {
            files = trackEntries.map { track in
                DeviceFile(
                    objectID: track.trackID,
                    name: track.displayFileName,
                    type: .audio,
                    size: track.fileSize,
                    path: musicPath(for: track),
                    backendKind: .mtp,
                    audioMetadata: DeviceAudioMetadata(
                        title: track.title,
                        artist: track.artist,
                        album: track.album
                    )
                )
            }
        } else {
            files = buildAudioFiles(from: fileEntries)
        }

        files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let playlistEntries = parsePlaylists(playlistsOutput ?? "")
        let collections = buildCollections(
            playlistEntries: playlistEntries,
            files: files
        )

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        return DeviceFileSystemSnapshot(
            files: files,
            collections: collections,
            storageInfo: DeviceStorageInfo(
                totalCapacity: nil,
                availableCapacity: nil,
                usedByFiles: totalBytes,
                fileCount: files.count
            ),
            deviceName: parseDeviceName(joinedOutput),
            diagnosticMessage: diagnosticMessage(
                fileCount: files.count,
                playlistCount: collections.filter { $0.kind == .playlist }.count,
                rawObjectCount: max(trackEntries.count, fileEntries.count)
            )
        )
    }

    public static func makeStorageSnapshot(filesOutput: String, deviceOutput: String? = nil) throws -> DeviceFileSystemSnapshot {
        try validateMTPOutput(filesOutput, allowNoPlaylists: true)
        let entries = parseFilesystem(filesOutput)
        let files = buildStorageFiles(from: entries)
        let totalBytes = files.reduce(Int64(0)) { $0 + max($1.size, 0) }

        return DeviceFileSystemSnapshot(
            files: files,
            collections: [
                DeviceCollection(
                    id: "all-storage",
                    name: "All Storage",
                    kind: .folder,
                    fileIDs: files.map(\.id)
                )
            ],
            storageInfo: DeviceStorageInfo(
                totalCapacity: nil,
                availableCapacity: nil,
                usedByFiles: totalBytes,
                fileCount: files.count
            ),
            deviceName: parseDeviceName([filesOutput, deviceOutput].compactMap { $0 }.joined(separator: "\n")),
            diagnosticMessage: nil
        )
    }

    public static func validateMTPOutput(_ output: String, allowNoPlaylists: Bool = false) throws {
        let lowerOutput = output.lowercased()
        if lowerOutput.contains("no devices have been found")
            || lowerOutput.contains("no raw devices found")
            || lowerOutput.contains("no devices found")
            || lowerOutput.contains("no devices.") {
            throw MTPHelperError(
                code: "no-device",
                message: "No Garmin MTP device is responding.",
                recoverySuggestion: "Connect the watch with a data USB cable, wake it, close Garmin Express or other transfer apps, then refresh."
            )
        }
        if outputReportsConnectionFailure(output) {
            throw MTPHelperError(
                code: "device-busy",
                message: userFacingMTPError(from: output)
            )
        }
        if allowNoPlaylists && lowerOutput.contains("no playlists") {
            return
        }
    }

    public static func parseTracks(_ output: String) -> [MTPTrackEntry] {
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
            if line.hasPrefix("Track ID:") || line.hasPrefix("TrackID:") {
                flush()
                currentID = value(afterColonIn: line)
            } else if line.hasPrefix("Title:") || line.hasPrefix("Track title:") {
                currentTitle = value(afterColonIn: line)
            } else if line.hasPrefix("Artist:") {
                currentArtist = value(afterColonIn: line)
            } else if line.hasPrefix("Album:") {
                currentAlbum = value(afterColonIn: line)
            } else if line.hasPrefix("Origfilename:") || line.hasPrefix("Original filename:") || line.hasPrefix("Filename:") {
                currentOriginalFileName = value(afterColonIn: line)
            } else if line.lowercased().hasPrefix("file size") || line.lowercased().hasPrefix("filesize") {
                currentSize = parseLeadingInteger(afterColonOrTextIn: line)
            } else if line.hasPrefix("Filetype:") || line.hasPrefix("File type:") {
                currentType = value(afterColonIn: line)
            }
        }
        flush()

        return entries
    }

    public static func parseFilesystem(_ output: String) -> [MTPRawEntry] {
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
            if line.hasPrefix("File ID:") || line.hasPrefix("Object ID:") {
                flush()
                currentID = value(afterColonIn: line)
            } else if line.hasPrefix("Filename:") || line.hasPrefix("File name:") || line.hasPrefix("Name:") {
                currentName = value(afterColonIn: line)
            } else if line.lowercased().hasPrefix("file size") || line.lowercased().hasPrefix("filesize") {
                currentSize = parseLeadingInteger(afterColonOrTextIn: line)
            } else if line.hasPrefix("Parent ID:") || line.hasPrefix("Parent:") {
                currentParentID = value(afterColonIn: line)
            } else if line.hasPrefix("Storage ID:") {
                currentStorageID = value(afterColonIn: line)
            } else if line.hasPrefix("Filetype:") || line.hasPrefix("File type:") {
                currentType = value(afterColonIn: line)
            }
        }
        flush()

        return entries
    }

    public static func parsePlaylists(_ output: String) -> [MTPPlaylistEntry] {
        var entries: [MTPPlaylistEntry] = []
        var currentID: String?
        var currentName: String?
        var currentTracks: [MTPPlaylistTrackReference] = []

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
            guard !line.isEmpty else { continue }

            if line.hasPrefix("Playlist ID:") || line.hasPrefix("PlaylistID:") {
                flush()
                currentID = value(afterColonIn: line)
            } else if line.hasPrefix("Playlist:") {
                flush()
                currentName = value(afterColonIn: line)
                currentID = normalizedIdentifier(from: currentName ?? line)
            } else if line.hasPrefix("Name:"), currentName == nil {
                currentName = value(afterColonIn: line)
            } else if line.hasPrefix("Object ID:"), currentID == nil {
                currentID = value(afterColonIn: line)
            } else if let trackReference = parsePlaylistTrackReference(line) {
                currentTracks.append(trackReference)
            }
        }
        flush()

        return entries
    }

    public static func parseDeviceName(_ output: String) -> String? {
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

    private static func buildAudioFiles(from entries: [MTPRawEntry]) -> [DeviceFile] {
        buildStorageFiles(from: entries).filter { $0.type == .audio }
    }

    private static func buildStorageFiles(from entries: [MTPRawEntry]) -> [DeviceFile] {
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.fileID, $0) })
        var pathCache: [String: String] = [:]

        func resolvePath(for entry: MTPRawEntry) -> String {
            if let cached = pathCache[entry.fileID] {
                return cached
            }
            let name = entry.filename
            guard
                let parentID = entry.parentID,
                let parent = entriesByID[parentID],
                parent.fileID != entry.fileID
            else {
                pathCache[entry.fileID] = name
                return name
            }
            let parentPath = resolvePath(for: parent)
            let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
            pathCache[entry.fileID] = path
            return path
        }

        return entries.map { entry in
            DeviceFile(
                objectID: entry.fileID,
                name: entry.filename,
                type: fileType(for: entry),
                size: entry.fileSize,
                parentID: entry.parentID,
                path: resolvePath(for: entry),
                backendKind: .mtp
            )
        }
        .sorted {
            if $0.type == .folder, $1.type != .folder { return true }
            if $0.type != .folder, $1.type == .folder { return false }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private static func buildCollections(
        playlistEntries: [MTPPlaylistEntry],
        files: [DeviceFile]
    ) -> [DeviceCollection] {
        var collections: [DeviceCollection] = [
            DeviceCollection(
                id: "all-music",
                name: "All Music",
                kind: .allMusic,
                fileIDs: files.map(\.id)
            )
        ]

        let filesByObjectID = Dictionary(uniqueKeysWithValues: files.compactMap { file in
            file.objectID.map { ($0, file) }
        })
        let filesByNormalizedName = Dictionary(grouping: files) { normalizedName($0.name) }

        for playlist in playlistEntries {
            var fileIDs: [String] = []
            var unmatched: [String] = []

            for reference in playlist.trackReferences {
                if let file = filesByObjectID[reference.trackID] {
                    fileIDs.append(file.id)
                } else if let file = filesByNormalizedName[normalizedName(reference.displayName)]?.first {
                    fileIDs.append(file.id)
                } else {
                    unmatched.append(reference.displayName.isEmpty ? "Track \(reference.trackID)" : reference.displayName)
                }
            }

            collections.append(DeviceCollection(
                id: "playlist:\(playlist.playlistID)",
                name: playlist.name,
                kind: .playlist,
                fileIDs: fileIDs,
                unmatchedItems: unmatched
            ))
        }

        let explicitPlaylistNames = Set(playlistEntries.map { normalizedName($0.name) })
        let byAlbum = Dictionary(grouping: files) { file in
            file.audioMetadata?.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        for (album, albumFiles) in byAlbum.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            guard !album.isEmpty, albumFiles.count > 1 else { continue }
            guard !explicitPlaylistNames.contains(normalizedName(album)) else { continue }
            collections.append(DeviceCollection(
                id: "album:\(album)",
                name: album,
                kind: .album,
                fileIDs: albumFiles.map(\.id)
            ))
        }

        return collections.filter { collection in
            collection.kind == .allMusic || collection.totalItemCount > 0
        }
    }

    private static func fileType(for entry: MTPRawEntry) -> DeviceFileType {
        if entry.isFolder { return .folder }
        if entry.isAudio { return .audio }
        if entry.isPlaylist { return .playlist }
        return .other
    }

    private static func musicPath(for track: MTPTrackEntry) -> String {
        let folder = track.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let folder, !folder.isEmpty {
            return "Music/\(folder)/\(track.displayFileName)"
        }
        return "Music/\(track.displayFileName)"
    }

    private static func diagnosticMessage(fileCount: Int, playlistCount: Int, rawObjectCount: Int) -> String? {
        if fileCount > 0 || playlistCount > 0 {
            return nil
        }
        if rawObjectCount > 0 {
            return "Garmin responded with \(rawObjectCount) MTP object(s), but none were exposed as supported audio files. Streaming-provider music can be hidden or protected."
        }
        return "Garmin responded, but did not expose any music files or playlists over MTP."
    }

    private static func parsePlaylistTrackReference(_ line: String) -> MTPPlaylistTrackReference? {
        if line.localizedCaseInsensitiveContains("INVALID TRACK REFERENCE") {
            return nil
        }

        let patterns = [
            #"^\s*(\d+)\s*:\s*(.+)$"#,
            #"(?i)^\s*track\s+(\d+)\s*:\s*(.+)$"#,
            #"(?i)^\s*track\s+id\s*:\s*(\d+)\s*(?:-|:)?\s*(.*)$"#,
            #"(?i)^\s*object\s+id\s*:\s*(\d+)\s*(?:-|:)?\s*(.*)$"#,
            #"(?i).*track(?:\s+object)?\s*id\s*[=:]\s*(\d+).*?(?:name|title|file)\s*[=:]\s*(.+)$"#
        ]

        for pattern in patterns {
            if let captures = captures(in: line, pattern: pattern), let id = captures.first, !id.isEmpty {
                let displayName = captures.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Track \(id)"
                return MTPPlaylistTrackReference(trackID: id, displayName: displayName.isEmpty ? "Track \(id)" : displayName)
            }
        }

        return nil
    }

    private static func value(afterColonIn line: String) -> String? {
        guard let range = line.range(of: ":") else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseLeadingInteger(afterColonOrTextIn line: String) -> Int64 {
        let raw = value(afterColonIn: line) ?? line
        let digits = raw.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int64(digits) ?? 0
    }

    private static func normalizedIdentifier(from value: String) -> String {
        normalizedName(value).replacingOccurrences(of: " ", with: "-")
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func captures(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }

        var result: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text) else {
                result.append("")
                continue
            }
            result.append(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
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
            return "Garmin is visible, but MTP could not open the USB connection."
        }

        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.last ?? "MTP command failed."
    }
}

public struct MTPRawEntry: Codable, Hashable {
    public var fileID: String
    public var filename: String
    public var fileSize: Int64
    public var parentID: String?
    public var storageID: String?
    public var filetype: String?

    public init(
        fileID: String,
        filename: String,
        fileSize: Int64,
        parentID: String?,
        storageID: String?,
        filetype: String?
    ) {
        self.fileID = fileID
        self.filename = filename
        self.fileSize = fileSize
        self.parentID = parentID
        self.storageID = storageID
        self.filetype = filetype
    }

    public var isFolder: Bool {
        let type = filetype?.lowercased() ?? ""
        return type.contains("association") || type.contains("directory") || type.contains("folder")
    }

    public var isAudio: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        let type = filetype?.lowercased() ?? ""
        let audioTypeHints = ["audio", "mp3", "mp4", "aac", "wav", "mpeg", "flac"]
        return MTPOutputParser.supportsAudioExtension(ext)
            || audioTypeHints.contains(where: { type.contains($0) })
    }

    public var isPlaylist: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return MTPOutputParser.supportsPlaylistExtension(ext)
    }
}

public struct MTPTrackEntry: Codable, Hashable {
    public var trackID: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var originalFileName: String?
    public var fileSize: Int64
    public var filetype: String?

    public init(
        trackID: String,
        title: String?,
        artist: String?,
        album: String?,
        originalFileName: String?,
        fileSize: Int64,
        filetype: String?
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.originalFileName = originalFileName
        self.fileSize = fileSize
        self.filetype = filetype
    }

    public var displayFileName: String {
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
        if type.contains("flac") { return "flac" }
        return nil
    }
}

public struct MTPPlaylistEntry: Codable, Hashable {
    public var playlistID: String
    public var name: String
    public var trackReferences: [MTPPlaylistTrackReference]

    public init(
        playlistID: String,
        name: String,
        trackReferences: [MTPPlaylistTrackReference]
    ) {
        self.playlistID = playlistID
        self.name = name
        self.trackReferences = trackReferences
    }
}

public struct MTPPlaylistTrackReference: Codable, Hashable {
    public var trackID: String
    public var displayName: String

    public init(trackID: String, displayName: String) {
        self.trackID = trackID
        self.displayName = displayName
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }
}

public extension MTPOutputParser {
    static func supportsAudioExtension(_ ext: String) -> Bool {
        supportedAudioExtensions.contains(ext.lowercased())
    }

    static func supportsPlaylistExtension(_ ext: String) -> Bool {
        supportedPlaylistExtensions.contains(ext.lowercased())
    }
}
