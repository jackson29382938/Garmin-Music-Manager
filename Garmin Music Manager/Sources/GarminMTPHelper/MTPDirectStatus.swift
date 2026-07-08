import CLibMTP
import Foundation
import GarminMusicCore

enum MTPDirectStatus {
    static func current(fileManager: FileManager = .default) -> MTPToolStatus {
        // Prefer reporting where libmtp is actually loadable: bundled Frameworks
        // next to this helper, then Homebrew system paths.
        let executableDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let frameworksDir = executableDir
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks")

        let libraryPath = firstExistingPath([
            frameworksDir.appendingPathComponent("libmtp.9.dylib").path,
            frameworksDir.appendingPathComponent("libmtp.dylib").path,
            "/opt/homebrew/lib/libmtp.dylib",
            "/opt/homebrew/lib/libmtp.9.dylib",
            "/usr/local/lib/libmtp.dylib",
            "/usr/local/lib/libmtp.9.dylib"
        ], fileManager: fileManager)

        let headerPath = firstExistingPath([
            "/opt/homebrew/include/libmtp.h",
            "/usr/local/include/libmtp.h"
        ], fileManager: fileManager)

        return MTPToolStatus(
            connectionBackend: "direct-libmtp",
            libmtpVersion: "\(LIBMTP_VERSION_STRING)",
            libmtpLibraryPath: libraryPath,
            libmtpHeaderPath: headerPath
        )
    }

    private static func firstExistingPath(_ paths: [String], fileManager: FileManager) -> String? {
        paths.first { fileManager.fileExists(atPath: $0) }
    }
}

