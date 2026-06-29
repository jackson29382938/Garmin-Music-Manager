import Foundation
import SwiftUI

struct GarminDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let volumeURL: URL
    let suggestedMusicFolderURL: URL
    let kind: DeviceKind
}

enum DeviceKind: String, Hashable {
    case mountedVolume = "Mounted Volume"
    case mtp = "MTP Device"
}

struct EditableMetadata: Hashable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var trackNumber: String = ""

    var ffmpegArguments: [String] {
        var args: [String] = []
        if !title.trimmed.isEmpty { args += ["-metadata", "title=\(title.trimmed)"] }
        if !artist.trimmed.isEmpty { args += ["-metadata", "artist=\(artist.trimmed)"] }
        if !album.trimmed.isEmpty { args += ["-metadata", "album=\(album.trimmed)"] }
        if !trackNumber.trimmed.isEmpty { args += ["-metadata", "track=\(trackNumber.trimmed)"] }
        return args
    }
}

struct MusicTrack: Identifiable, Hashable {
    let id = UUID()
    let originalURL: URL
    var workingURL: URL?
    let fileName: String
    let fileExtension: String
    var metadata: EditableMetadata
    let duration: Double?
    let fileSizeBytes: Int?
    var issues: [TrackIssue]
    var isSelected: Bool
    var generatedCopyReason: String?

    var sourceURLForSync: URL { workingURL ?? originalURL }

    var status: TrackStatus {
        if issues.contains(where: { $0.severity == .unsupported }) { return .unsupported }
        if issues.contains(where: { $0.severity == .warning }) { return .warning }
        return .ready
    }

    var displayTitle: String {
        metadata.title.trimmed.nilIfEmpty ?? fileName
    }

    var subtitle: String {
        var pieces: [String] = []
        if let artist = metadata.artist.trimmed.nilIfEmpty { pieces.append(artist) }
        if let album = metadata.album.trimmed.nilIfEmpty { pieces.append(album) }
        if let duration { pieces.append(DurationFormatter.format(duration)) }
        if let fileSizeBytes { pieces.append(ByteCountFormatter.string(fromByteCount: Int64(fileSizeBytes), countStyle: .file)) }
        if let generatedCopyReason { pieces.append("Generated: \(generatedCopyReason)") }
        return pieces.isEmpty ? "No metadata found" : pieces.joined(separator: " • ")
    }

    var playlistDisplayName: String {
        if let artist = metadata.artist.trimmed.nilIfEmpty {
            return "\(artist) - \(displayTitle)"
        }
        return displayTitle
    }

    var searchableText: String {
        [fileName, metadata.title, metadata.artist, metadata.album, status.label, issues.map(\.message).joined(separator: " ")]
            .joined(separator: " ")
            .lowercased()
    }
}

enum TrackStatus: Hashable {
    case ready
    case warning
    case unsupported

    var label: String {
        switch self {
        case .ready: return "ready"
        case .warning: return "warning"
        case .unsupported: return "unsupported"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unsupported: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .unsupported: return .red
        }
    }
}

struct TrackIssue: Identifiable, Hashable {
    let id = UUID()
    let severity: Severity
    let message: String

    enum Severity: Hashable {
        case warning
        case unsupported

        var symbolName: String {
            switch self {
            case .warning: return "exclamationmark.triangle"
            case .unsupported: return "xmark.octagon"
            }
        }

        var tint: Color {
            switch self {
            case .warning: return .orange
            case .unsupported: return .red
            }
        }
    }
}

enum DestinationHealth {
    case unknown
    case valid
    case warning
    case invalid
}

struct DestinationValidationResult {
    let availableCapacity: Int64?
    let warnings: [String]
    let messages: [String]
}

struct SyncPlan {
    struct Entry {
        let track: MusicTrack
        let destinationURL: URL
    }

    let destinationRootURL: URL?
    let syncFolderURL: URL?
    let playlistURL: URL?
    let entries: [Entry]
    let totalBytes: Int64
    let availableCapacity: Int64?
    let warnings: [String]
    let useMTP: Bool

    var summaryMessages: [String] {
        var messages = [
            "Tracks to sync: \(entries.count)",
            "Estimated size: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        ]
        if let syncFolderURL { messages.append("Destination folder: \(syncFolderURL.path)") }
        if useMTP { messages.append("Experimental MTP mode is enabled.") }
        messages.append(contentsOf: warnings)
        return messages
    }

    var debugSummary: String {
        var lines = summaryMessages
        lines += entries.map { "- \($0.track.sourceURLForSync.path) -> \($0.destinationURL.path)" }
        return lines.joined(separator: "\n")
    }
}

struct SyncResult {
    let copied: Int
    let failed: Int
    let playlistURL: URL?
    let failures: [String]

    var summaryMessages: [String] {
        var messages = ["Copied: \(copied)", "Failed: \(failed)"]
        if let playlistURL { messages.append("Playlist: \(playlistURL.path)") }
        messages.append(contentsOf: failures)
        return messages
    }

    var debugSummary: String { summaryMessages.joined(separator: "\n") }
}

enum ConversionPreset: String, CaseIterable, Identifiable {
    case aac192 = "AAC 192 kbps (.m4a)"
    case mp3192 = "MP3 192 kbps (.mp3)"

    var id: String { rawValue }

    var outputExtension: String {
        switch self {
        case .aac192: return "m4a"
        case .mp3192: return "mp3"
        }
    }

    var ffmpegCodecArgs: [String] {
        switch self {
        case .aac192: return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .mp3192: return ["-vn", "-c:a", "libmp3lame", "-b:a", "192k"]
        }
    }
}

enum LogLevel: String, Hashable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var tint: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let date = Date()
    let level: LogLevel
    let message: String
    let detail: String?

    var formatted: String {
        var output = "[\(Self.formatter.string(from: date))] [\(level.rawValue)] \(message)"
        if let detail, !detail.isEmpty { output += "\n    \(detail.replacingOccurrences(of: "\n", with: "\n    "))" }
        return output
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

enum AppError: LocalizedError, CustomDebugStringConvertible {
    case noDestination
    case noTracksSelected
    case destinationIsNotDirectory(String)
    case destinationNotWritable(String, String)
    case externalToolMissing(String)
    case commandFailed(String, Int32, String)
    case conversionFailed(String)
    case metadataRepairFailed(String)
    case mtpUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noDestination: return "No destination selected."
        case .noTracksSelected: return "No compatible selected tracks to sync."
        case .destinationIsNotDirectory(let path): return "Destination is not a folder: \(path)"
        case .destinationNotWritable(let path, _): return "Destination is not writable: \(path)"
        case .externalToolMissing(let tool): return "Required tool not found: \(tool)"
        case .commandFailed(let command, let status, _): return "Command failed (\(status)): \(command)"
        case .conversionFailed(let detail): return "Audio conversion failed: \(detail)"
        case .metadataRepairFailed(let detail): return "Metadata repair failed: \(detail)"
        case .mtpUnavailable(let detail): return "MTP support is unavailable: \(detail)"
        }
    }

    var debugDescription: String {
        switch self {
        case .destinationNotWritable(let path, let detail): return "Destination not writable: \(path)\n\(detail)"
        case .commandFailed(let command, let status, let output): return "Command: \(command)\nExit status: \(status)\nOutput:\n\(output)"
        default: return errorDescription ?? String(describing: self)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}

enum DurationFormatter {
    static func format(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
