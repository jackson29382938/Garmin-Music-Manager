import Foundation
import GarminMusicCore

struct AudioConverter {
    enum ConverterError: LocalizedError {
        case ffmpegMissing
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing:
                return "ffmpeg is not installed. Install it with Homebrew to convert ALAC/FLAC files."
            case .conversionFailed(let message):
                return message
            }
        }
    }

    private let fileManager = FileManager.default

    /// Optional absolute path override (Library/Conversion settings).
    static var customFFmpegPath: String?

    static var temporaryConversionDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GarminMusicManager-conversions", isDirectory: true)
    }

    var isAvailable: Bool {
        ffmpegURL != nil
    }

    static func clearTemporaryConversions(fileManager: FileManager = .default) throws {
        let directory = temporaryConversionDirectory
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Converts source audio to AAC.
    /// - Parameters:
    ///   - bitrateKbps: Target bitrate (64…320).
    ///   - sampleRate: Optional fixed sample rate; `nil` / `.source` keeps input rate.
    ///   - reuseExisting: When true, return existing cache file if present.
    func convertToAAC(
        source: URL,
        bitrateKbps: Int = 256,
        sampleRate: AACSampleRate = .hz44100,
        reuseExisting: Bool = true
    ) throws -> URL {
        guard let ffmpegURL else {
            throw ConverterError.ffmpegMissing
        }

        let outputDirectory = Self.temporaryConversionDirectory
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let rateTag: String
        switch sampleRate {
        case .source: rateTag = "src"
        case .hz44100: rateTag = "44100"
        case .hz48000: rateTag = "48000"
        }

        let bitrate = min(320, max(64, bitrateKbps))

        // Content-addressed cache name: fold source identity (path + size +
        // mtime) and encode parameters into the file name so two different
        // sources that share a base filename never collide and reuse the wrong
        // audio. See ConversionCacheNaming for the regression details.
        let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path)
        let sourceSize = (sourceAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        let sourceModified = Int64(((sourceAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).rounded())
        let outputURL = outputDirectory.appendingPathComponent(
            ConversionCacheNaming.cacheFileName(
                sourcePath: source.path,
                sourceSizeBytes: sourceSize,
                sourceModifiedEpoch: sourceModified,
                bitrateKbps: bitrate,
                sampleRateTag: rateTag
            )
        )

        if reuseExisting, fileManager.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        var arguments = [
            "-nostdin",
            "-nostats",
            "-loglevel", "error",
            "-y",
            "-i", source.path,
            "-c:a", "aac",
            "-b:a", "\(bitrate)k"
        ]
        if sampleRate != .source {
            arguments += ["-ar", "\(sampleRate.rawValue)"]
        }
        arguments.append(outputURL.path)

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments

        // ffmpeg writes the encode to `outputURL`, not stdout, so discard stdout.
        // stderr is captured for diagnostics. `-nostats -loglevel error` keeps
        // stderr tiny; combined with draining it (below) this avoids the pipe
        // buffer filling and dead-locking a long conversion.
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice

        let stderrBuffer = LockedByteBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(chunk)
            }
        }

        try process.run()

        let deadline = Date().addingTimeInterval(600)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ConverterError.conversionFailed("ffmpeg timed out while converting \(source.lastPathComponent).")
        }

        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0, fileManager.fileExists(atPath: outputURL.path) else {
            let stderr = stderrBuffer.string().trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConverterError.conversionFailed(stderr.isEmpty ? "ffmpeg failed." : stderr)
        }

        return outputURL
    }

    private var ffmpegURL: URL? {
        if let custom = Self.customFFmpegPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in searchPaths {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

/// Thread-safe byte accumulator for draining a pipe on its readability queue
/// while the main thread waits for the process to exit.
private final class LockedByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
