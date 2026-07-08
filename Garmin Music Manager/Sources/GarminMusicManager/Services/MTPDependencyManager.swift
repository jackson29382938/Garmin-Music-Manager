import Foundation

struct MTPDependencyStatus: Equatable {
    let homebrewURL: URL?
    let libmtpLibraryURL: URL?
    let libmtpHeaderURL: URL?
    /// Path to `GarminMTPHelper` (bundled in the .app, or beside a SwiftPM build).
    let helperURL: URL?
    /// Bundled `libmtp` inside the .app Frameworks folder (no Homebrew required).
    let bundledLibmtpURL: URL?

    /// Runtime readiness: a helper binary plus a loadable libmtp (bundled or system).
    /// Headers are a *build* dependency only and are not required here.
    var isReady: Bool {
        guard helperURL != nil else { return false }
        if bundledLibmtpURL != nil { return true }
        return libmtpLibraryURL != nil
    }

    /// True when installing Homebrew/libmtp is a useful recovery path.
    var canInstallViaHomebrew: Bool {
        !isReady && bundledLibmtpURL == nil
    }

    var message: String {
        if isReady {
            if bundledLibmtpURL != nil {
                return "MTP support ready (bundled helper + libmtp)."
            }
            return "MTP support ready (direct libmtp)."
        }
        if helperURL == nil {
            return "Garmin MTP helper is missing. Rebuild the app (make app) or run from the package directory."
        }
        if bundledLibmtpURL == nil, libmtpLibraryURL == nil {
            if homebrewURL == nil {
                return "libmtp is not available. Use Install MTP (Homebrew) or open the packaged app that bundles libmtp."
            }
            return "Homebrew is installed, but the libmtp library is missing. Use Install MTP to install it."
        }
        return "MTP support is not ready."
    }

    static let unavailable = MTPDependencyStatus(
        homebrewURL: nil,
        libmtpLibraryURL: nil,
        libmtpHeaderURL: nil,
        helperURL: nil,
        bundledLibmtpURL: nil
    )
}

final class MTPDependencyManager {
    private let fileManager = FileManager.default

    private static let mtpEnvironment = """
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    export LC_CTYPE=en_US.UTF-8
    """

    func dependencyStatus() -> MTPDependencyStatus {
        let helper = MTPHelperClient.locateHelper()
        return MTPDependencyStatus(
            homebrewURL: executableURL(named: "brew"),
            libmtpLibraryURL: firstExistingPath([
                "/opt/homebrew/lib/libmtp.dylib",
                "/opt/homebrew/lib/libmtp.9.dylib",
                "/usr/local/lib/libmtp.dylib",
                "/usr/local/lib/libmtp.9.dylib"
            ]),
            libmtpHeaderURL: firstExistingPath([
                "/opt/homebrew/include/libmtp.h",
                "/usr/local/include/libmtp.h"
            ]),
            helperURL: helper,
            bundledLibmtpURL: bundledLibmtpURL(nearHelper: helper)
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

            if [ ! -f /opt/homebrew/lib/libmtp.dylib ] && [ ! -f /opt/homebrew/lib/libmtp.9.dylib ] \
               && [ ! -f /usr/local/lib/libmtp.dylib ] && [ ! -f /usr/local/lib/libmtp.9.dylib ]; then
              echo "Installing libmtp..."
              brew install libmtp
            elif [ ! -f /opt/homebrew/include/libmtp.h ] && [ ! -f /usr/local/include/libmtp.h ]; then
              echo "Reinstalling libmtp headers..."
              brew reinstall libmtp
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

    /// libmtp shipped inside a packaged .app next to the helper binary.
    func bundledLibmtpURL(nearHelper helperURL: URL?) -> URL? {
        guard let helperURL else { return nil }
        let macosDir = helperURL.deletingLastPathComponent()
        let candidates = [
            macosDir.deletingLastPathComponent().appendingPathComponent("Frameworks"),
            macosDir.appendingPathComponent("Frameworks")
        ]
        let names = ["libmtp.9.dylib", "libmtp.dylib"]
        for directory in candidates {
            for name in names {
                let url = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private func executableURL(named name: String) -> URL? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        for directory in searchPaths {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func firstExistingPath(_ paths: [String]) -> URL? {
        for path in paths {
            if fileManager.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
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

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            if surfaceOutput {
                for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                    output(String(line))
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
            let graceDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw MTPDependencyError.installTimedOut
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw MTPDependencyError.installFailed("Dependency install exited with status \(process.terminationStatus).")
        }
    }
}

enum MTPDependencyError: LocalizedError {
    case installTimedOut
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .installTimedOut:
            return "MTP dependency install timed out."
        case .installFailed(let message):
            return message
        }
    }
}
