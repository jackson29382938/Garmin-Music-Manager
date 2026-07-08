import Foundation

struct MTPDependencyStatus: Equatable {
    let homebrewURL: URL?
    let libmtpLibraryURL: URL?
    let libmtpHeaderURL: URL?

    var isReady: Bool {
        libmtpLibraryURL != nil && libmtpHeaderURL != nil
    }

    var message: String {
        if isReady { return "MTP support ready (direct libmtp)." }
        if homebrewURL == nil { return "Homebrew and libmtp are not installed." }
        if libmtpLibraryURL == nil { return "Homebrew is installed, but the libmtp library is missing." }
        return "Homebrew is installed, but the libmtp headers are missing."
    }
}

final class MTPDependencyManager {
    private let fileManager = FileManager.default

    private static let mtpEnvironment = """
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    export LC_CTYPE=en_US.UTF-8
    """

    func dependencyStatus() -> MTPDependencyStatus {
        MTPDependencyStatus(
            homebrewURL: executableURL(named: "brew"),
            libmtpLibraryURL: firstExistingPath([
                "/opt/homebrew/lib/libmtp.dylib",
                "/usr/local/lib/libmtp.dylib"
            ]),
            libmtpHeaderURL: firstExistingPath([
                "/opt/homebrew/include/libmtp.h",
                "/usr/local/include/libmtp.h"
            ])
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

            if [ ! -f /opt/homebrew/lib/libmtp.dylib ] && [ ! -f /usr/local/lib/libmtp.dylib ]; then
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
