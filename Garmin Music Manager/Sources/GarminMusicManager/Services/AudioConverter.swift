import Foundation

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

    func convertToAAC(source: URL) throws -> URL {
        guard let ffmpegURL else {
            throw ConverterError.ffmpegMissing
        }

        let outputDirectory = Self.temporaryConversionDirectory
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let stem = source.deletingPathExtension().lastPathComponent
        let outputURL = outputDirectory.appendingPathComponent("\(stem)-converted.m4a")

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-y",
            "-i", source.path,
            "-c:a", "aac",
            "-b:a", "256k",
            outputURL.path
        ]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()

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
            throw ConverterError.conversionFailed("ffmpeg timed out while converting \(source.lastPathComponent).")
        }

        guard process.terminationStatus == 0, fileManager.fileExists(atPath: outputURL.path) else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ConverterError.conversionFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ffmpeg failed." : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return outputURL
    }

    private var ffmpegURL: URL? {
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
