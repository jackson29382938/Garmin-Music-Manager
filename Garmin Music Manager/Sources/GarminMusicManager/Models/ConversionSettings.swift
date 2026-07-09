import Foundation

enum AACSampleRate: Int, CaseIterable, Identifiable, Codable {
    case source = 0
    case hz44100 = 44100
    case hz48000 = 48000

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .source: return "Match source"
        case .hz44100: return "44.1 kHz"
        case .hz48000: return "48 kHz"
        }
    }
}

/// Conversion quality and cache preferences (works with Performance AAC bitrate).
struct ConversionSettings: Codable, Equatable {
    var aacSampleRate: AACSampleRate
    /// Keep converted m4a files on disk for re-use across sends.
    var keepConversionCache: Bool
    /// Delete conversion cache after a successful send.
    var clearCacheAfterSuccessfulSend: Bool
    /// Optional absolute path to ffmpeg; empty = auto-discover.
    var customFFmpegPath: String
    /// Also offer conversion for WAV when convert-incompatible is on.
    var convertWAV: Bool

    static let `default` = ConversionSettings(
        aacSampleRate: .hz44100,
        keepConversionCache: true,
        clearCacheAfterSuccessfulSend: false,
        customFFmpegPath: "",
        convertWAV: false
    )

    var clamped: ConversionSettings { self }

    var resolvedFFmpegPath: String? {
        let trimmed = customFFmpegPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
