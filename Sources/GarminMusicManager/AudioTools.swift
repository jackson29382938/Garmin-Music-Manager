import AVFoundation
import Foundation

enum MusicInspector {
    static let supportedExtensions = ["mp3", "m4a", "aac", "m4b", "wav"]
    static let knownUnsupportedExtensions = ["aif", "aiff", "alac", "flac", "m4p", "ogg", "opus", "wma"]
    static let scanExtensions = supportedExtensions + knownUnsupportedExtensions

    struct ScanResult {
        let urls: [URL]
        let skippedPaths: [String]
    }

    static func findCandidateAudioFiles(in folderURL: URL) -> ScanResult {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ScanResult(urls: [], skippedPaths: [folderURL.path])
        }

        var urls: [URL] = []
        var skippedPaths: [String] = []

        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
                guard values.isRegularFile == true else { continue }
                guard values.isReadable == true else {
                    skippedPaths.append(url.path)
                    continue
                }
            } catch {
                skippedPaths.append(url.path)
                continue
            }

            if scanExtensions.contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }

        return ScanResult(urls: urls, skippedPaths: skippedPaths)
    }

    static func inspect(url: URL) -> MusicTrack {
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let asset = AVURLAsset(url: url)
        let metadataItems = asset.commonMetadata

        let metadata = EditableMetadata(
            title: metadataItems.commonString(for: .commonKeyTitle) ?? "",
            artist: metadataItems.commonString(for: .commonKeyArtist) ?? "",
            album: metadataItems.commonString(for: .commonKeyAlbumName) ?? "",
            trackNumber: ""
        )

        let durationSeconds = asset.duration.seconds.isFinite ? asset.duration.seconds : nil
        let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        var issues: [TrackIssue] = []

        if knownUnsupportedExtensions.contains(ext) {
            issues.append(.init(severity: .unsupported, message: ".\(ext) needs conversion before Garmin sync."))
        } else if !supportedExtensions.contains(ext) {
            issues.append(.init(severity: .unsupported, message: "Unsupported or unknown file extension: .\(ext)."))
        }

        if ext == "m4a" || ext == "m4b" {
            issues.append(.init(severity: .warning, message: "M4A/M4B can be AAC or lossless. Convert if the watch rejects it."))
        }

        if metadata.title.trimmed.isEmpty {
            issues.append(.init(severity: .warning, message: "Missing title metadata; use Repair Metadata before syncing."))
        }

        if metadata.artist.trimmed.isEmpty {
            issues.append(.init(severity: .warning, message: "Missing artist metadata; sorting/display may be less useful."))
        }

        if durationSeconds == nil {
            issues.append(.init(severity: .warning, message: "Could not read duration; file may be damaged or unsupported."))
        }

        if let fileSize, fileSize > 250_000_000 {
            issues.append(.init(severity: .warning, message: "Large file; consider converting/compressing before copying."))
        }

        return MusicTrack(
            originalURL: url,
            workingURL: nil,
            fileName: fileName,
            fileExtension: ext,
            metadata: metadata,
            duration: durationSeconds,
            fileSizeBytes: fileSize,
            issues: issues,
            isSelected: issues.contains(where: { $0.severity == .unsupported }) == false,
            generatedCopyReason: nil
        )
    }
}

extension Array where Element == AVMetadataItem {
    func commonString(for key: AVMetadataKey) -> String? {
        first(where: { $0.commonKey == key })?.stringValue
    }
}

enum AudioWorkspace {
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GarminMusicManager/GeneratedAudio", isDirectory: true)
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    static func outputURL(for track: MusicTrack, preset: ConversionPreset, suffix: String) throws -> URL {
        try prepare()
        let base = FileNameSanitizer.safeStem(for: track)
        return FileNameSanitizer.uniqueURL(
            in: cacheDirectory,
            preferredFileName: "\(base)-\(suffix).\(preset.outputExtension)"
        )
    }
}

enum AudioConverter {
    static var isAvailable: Bool { CommandRunner.isAvailable("ffmpeg") }

    static func convert(track: MusicTrack, preset: ConversionPreset, metadata: EditableMetadata?) throws -> URL {
        guard isAvailable else { throw AppError.externalToolMissing("ffmpeg") }
        let outputURL = try AudioWorkspace.outputURL(for: track, preset: preset, suffix: "converted")
        var args = ["-y", "-i", track.sourceURLForSync.path]
        args += preset.ffmpegCodecArgs
        if let metadata { args += metadata.ffmpegArguments }
        args.append(outputURL.path)

        do {
            _ = try CommandRunner.run("ffmpeg", arguments: args, timeoutSeconds: 600)
            return outputURL
        } catch {
            throw AppError.conversionFailed(String(describing: error))
        }
    }
}

enum MetadataRepairer {
    static var isAvailable: Bool { CommandRunner.isAvailable("ffmpeg") }

    static func repair(track: MusicTrack, metadata: EditableMetadata) throws -> URL {
        guard isAvailable else { throw AppError.externalToolMissing("ffmpeg") }
        let preset: ConversionPreset = track.fileExtension.lowercased() == "mp3" ? .mp3192 : .aac192
        let outputURL = try AudioWorkspace.outputURL(for: track, preset: preset, suffix: "metadata")
        var args = ["-y", "-i", track.sourceURLForSync.path, "-map", "0", "-c", "copy"]
        args += metadata.ffmpegArguments
        args.append(outputURL.path)

        do {
            _ = try CommandRunner.run("ffmpeg", arguments: args, timeoutSeconds: 300)
            return outputURL
        } catch {
            throw AppError.metadataRepairFailed(String(describing: error))
        }
    }
}

enum FileNameSanitizer {
    static func safeStem(for track: MusicTrack) -> String {
        let base = track.playlistDisplayName.nilIfEmpty
            ?? track.fileName.replacingOccurrences(of: ".\(track.fileExtension)", with: "")
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmed
        return cleaned.nilIfEmpty ?? "Track"
    }

    static func safeFileName(for track: MusicTrack) -> String {
        let ext = track.sourceURLForSync.pathExtension.nilIfEmpty ?? track.fileExtension
        return "\(safeStem(for: track)).\(ext)"
    }

    static func uniqueURL(in folderURL: URL, preferredFileName: String) -> URL {
        let preferredURL = folderURL.appendingPathComponent(preferredFileName)
        if !FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateURL = folderURL.appendingPathComponent("\(stem) \(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return folderURL.appendingPathComponent(UUID().uuidString + "." + ext)
    }
}
