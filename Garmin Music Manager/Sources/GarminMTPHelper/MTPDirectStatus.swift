import CLibMTP
import Foundation
import GarminMusicCore

enum MTPDirectStatus {
    static func current(fileManager: FileManager = .default) -> MTPToolStatus {
        MTPToolStatus(
            connectionBackend: "direct-libmtp",
            libmtpVersion: "\(LIBMTP_VERSION_STRING)",
            libmtpLibraryPath: firstExistingPath([
                "/opt/homebrew/lib/libmtp.dylib",
                "/usr/local/lib/libmtp.dylib"
            ], fileManager: fileManager),
            libmtpHeaderPath: firstExistingPath([
                "/opt/homebrew/include/libmtp.h",
                "/usr/local/include/libmtp.h"
            ], fileManager: fileManager)
        )
    }

    private static func firstExistingPath(_ paths: [String], fileManager: FileManager) -> String? {
        paths.first { fileManager.fileExists(atPath: $0) }
    }
}

