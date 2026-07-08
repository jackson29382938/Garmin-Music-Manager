import Darwin
import Foundation
import GarminMusicCore

@main
struct GarminMTPHelper {
    static func main() {
        let arguments = CommandLine.arguments
        let serveMode = arguments.contains("--serve")
        let output = JSONOutput.prepare()

        if serveMode {
            runServeLoop(output: output.handle)
        } else {
            runOneShot(output: output.handle)
        }
    }

    /// Long-lived mode: one JSON request per line on stdin, one JSON response per line on
    /// the response handle. Keeps a single MTP session open across requests so browse +
    /// multi-file sync avoids re-detecting the device and re-enumerating storage.
    private static func runServeLoop(output: FileHandle) {
        let runner = MTPHelperRunner(reuseSession: true)
        let stdin = FileHandle.standardInput

        while true {
            autoreleasepool {
                guard let lineData = readLineData(from: stdin) else {
                    runner.closeSession()
                    return
                }
                let trimmed = lineData.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return }

                let response: MTPHelperResponse
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let request = try decoder.decode(MTPHelperRequest.self, from: Data(trimmed.utf8))
                    if request.operation == .status, CommandLine.arguments.contains("--close-on-status") {
                        // reserved; status still returns diagnostics without closing
                    }
                    response = runner.handle(request)
                } catch let error as MTPHelperError {
                    response = MTPHelperResponse(ok: false, error: error)
                } catch {
                    response = MTPHelperResponse(
                        ok: false,
                        error: MTPHelperError(code: "helper-error", message: error.localizedDescription)
                    )
                }

                do {
                    try writeLine(response, to: output)
                } catch {
                    runner.closeSession()
                    return
                }
            }
        }
    }

    private static func runOneShot(output: FileHandle) {
        do {
            let requestData = FileHandle.standardInput.readDataToEndOfFile()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let request = try decoder.decode(MTPHelperRequest.self, from: requestData)
            let runner = MTPHelperRunner(reuseSession: false)
            let response = runner.handle(request)
            try write(response, to: output)
        } catch let error as MTPHelperError {
            try? write(MTPHelperResponse(ok: false, error: error), to: output)
        } catch {
            try? write(MTPHelperResponse(
                ok: false,
                error: MTPHelperError(code: "helper-error", message: error.localizedDescription)
            ), to: output)
        }
    }

    private static func write(_ response: MTPHelperResponse, to output: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(response)
        output.write(data)
    }

    private static func writeLine(_ response: MTPHelperResponse, to output: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(response)
        data.append(contentsOf: [0x0A]) // newline framing
        output.write(data)
        try output.synchronize()
    }

    /// Reads until `\n` or EOF. Returns nil on EOF with no pending bytes.
    private static func readLineData(from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: 1)
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                return String(data: buffer, encoding: .utf8)
            }
            if chunk[0] == 0x0A {
                return String(data: buffer, encoding: .utf8) ?? ""
            }
            buffer.append(chunk)
            // Guard against runaway input without a newline.
            if buffer.count > 32 * 1_024 * 1_024 {
                return String(data: buffer, encoding: .utf8)
            }
        }
    }
}

/// Captures a dedicated response FD, then silences libmtp chatter on stdout/stderr.
struct JSONOutput {
    let handle: FileHandle

    static func prepare() -> JSONOutput {
        let outputDescriptor = dup(STDOUT_FILENO)
        let handle = outputDescriptor >= 0
            ? FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
            : FileHandle.standardOutput

        let nullDescriptor = open("/dev/null", O_WRONLY)
        if nullDescriptor >= 0 {
            dup2(nullDescriptor, STDOUT_FILENO)
            dup2(nullDescriptor, STDERR_FILENO)
            close(nullDescriptor)
        } else {
            freopen("/dev/null", "w", stderr)
        }

        return JSONOutput(handle: handle)
    }
}
