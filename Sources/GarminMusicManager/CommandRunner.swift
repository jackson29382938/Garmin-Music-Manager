import Foundation

struct ShellCommandResult: Hashable {
    let executable: String
    let arguments: [String]
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var commandLine: String {
        ([executable] + arguments).map { arg in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }.joined(separator: " ")
    }
}

enum CommandLocator {
    static let commonSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    static func find(_ executableName: String) -> String? {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let paths = envPaths + commonSearchPaths

        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(executableName).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

enum CommandRunner {
    static func run(_ executableName: String, arguments: [String], timeoutSeconds: TimeInterval = 120) throws -> ShellCommandResult {
        guard let executablePath = CommandLocator.find(executableName) else {
            throw AppError.externalToolMissing(executableName)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let result = ShellCommandResult(
            executable: executableName,
            arguments: arguments,
            terminationStatus: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )

        if result.terminationStatus != 0 {
            throw AppError.commandFailed(result.commandLine, result.terminationStatus, result.combinedOutput)
        }

        return result
    }

    static func isAvailable(_ executableName: String) -> Bool {
        CommandLocator.find(executableName) != nil
    }
}
