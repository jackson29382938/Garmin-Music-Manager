import Foundation
import GarminMusicCore

@main
struct GarminMTPHelper {
    static func main() {
        do {
            let requestData = FileHandle.standardInput.readDataToEndOfFile()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let request = try decoder.decode(MTPHelperRequest.self, from: requestData)
            let runner = MTPHelperRunner()
            let response = runner.handle(request)
            try write(response)
        } catch let error as MTPHelperError {
            try? write(MTPHelperResponse(ok: false, error: error))
        } catch {
            try? write(MTPHelperResponse(
                ok: false,
                error: MTPHelperError(code: "helper-error", message: error.localizedDescription)
            ))
        }
    }

    private static func write(_ response: MTPHelperResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(response)
        FileHandle.standardOutput.write(data)
    }
}

private final class MTPHelperRunner {
    private let tools = MTPToolLocator()
    private let commands = CommandRunner()
    private let fileManager = FileManager.default

    func handle(_ request: MTPHelperRequest) -> MTPHelperResponse {
        do {
            switch request.operation {
            case .status:
                return MTPHelperResponse(ok: true, dependencyStatus: tools.status)
            case .detect:
                return try detect()
            case .listMusic:
                return try listMusic()
            case .listStorageTree:
                return try listStorageTree()
            case .download:
                return try download(request.files, to: request.destinationPath)
            case .upload:
                return try upload(request.uploadFiles)
            case .delete:
                return try delete(request.files)
            case .move:
                throw MTPHelperError(
                    code: "unsupported-move",
                    message: "This Garmin MTP connection does not report safe in-place move support."
                )
            case .storageInfo:
                return try listMusic()
            }
        } catch let error as MTPHelperError {
            return MTPHelperResponse(ok: false, error: error)
        } catch {
            return MTPHelperResponse(
                ok: false,
                error: MTPHelperError(code: "operation-failed", message: error.localizedDescription)
            )
        }
    }

    private func detect() throws -> MTPHelperResponse {
        guard let detectPath = tools.status.mtpDetectPath else {
            throw missing("mtp-detect is not installed.")
        }
        let output = try commands.run(executable: detectPath, arguments: [], timeout: 15)
        try MTPOutputParser.validateMTPOutput(output, allowNoPlaylists: true)
        let snapshot = DeviceFileSystemSnapshot(
            files: [],
            collections: [],
            storageInfo: nil,
            deviceName: MTPOutputParser.parseDeviceName(output),
            diagnosticMessage: nil
        )
        return MTPHelperResponse(ok: true, snapshot: snapshot, dependencyStatus: tools.status)
    }

    private func listMusic() throws -> MTPHelperResponse {
        guard tools.status.canListMusic else {
            throw missing("libmtp listing tools are not installed.")
        }

        let tracksOutput = try optionalOutput(toolPath: tools.status.mtpTracksPath, timeout: 45)
        let playlistsOutput = try optionalOutput(toolPath: tools.status.mtpPlaylistsPath, timeout: 30)

        var filesOutput: String?
        if MTPOutputParser.parseTracks(tracksOutput ?? "").isEmpty {
            filesOutput = try optionalOutput(toolPath: tools.status.mtpFilesPath, timeout: 90)
        }

        let snapshot = try MTPOutputParser.makeMusicSnapshot(
            tracksOutput: tracksOutput,
            filesOutput: filesOutput,
            playlistsOutput: playlistsOutput
        )
        return MTPHelperResponse(ok: true, snapshot: snapshot, dependencyStatus: tools.status)
    }

    private func listStorageTree() throws -> MTPHelperResponse {
        guard let filesPath = tools.status.mtpFilesPath else {
            throw missing("mtp-files is not installed.")
        }
        let output = try commands.run(executable: filesPath, arguments: [], timeout: 180)
        let snapshot = try MTPOutputParser.makeStorageSnapshot(filesOutput: output)
        return MTPHelperResponse(ok: true, snapshot: snapshot, dependencyStatus: tools.status)
    }

    private func download(_ files: [DeviceFile], to destinationPath: String?) throws -> MTPHelperResponse {
        guard let destinationPath, !destinationPath.isEmpty else {
            throw MTPHelperError(code: "missing-destination", message: "Choose a destination folder on this Mac.")
        }
        guard let getFilePath = tools.status.mtpGetFilePath else {
            throw missing("mtp-getfile is not installed.")
        }

        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var copied = 0
        var failures: [String] = []
        for file in files {
            guard let objectID = file.objectID else {
                failures.append(file.name)
                continue
            }
            do {
                let target = uniqueURL(in: destination, preferredFileName: sanitizedFileName(file.name, fallback: "Garmin Track"))
                _ = try commands.run(executable: getFilePath, arguments: [objectID, target.path], timeout: 600)
                guard fileManager.fileExists(atPath: target.path), fileSize(at: target) > 0 else {
                    try? fileManager.removeItem(at: target)
                    failures.append(file.name)
                    continue
                }
                copied += 1
            } catch {
                failures.append(file.name)
            }
        }

        return MTPHelperResponse(
            ok: failures.isEmpty,
            operationResult: DeviceFileOperationResult(
                completedCount: copied,
                failedItems: failures,
                message: resultMessage(action: "copied", count: copied, failures: failures.count)
            )
        )
    }

    private func upload(_ uploadFiles: [DeviceUploadFile]) throws -> MTPHelperResponse {
        guard tools.status.canUpload else {
            throw missing("mtp-sendtr or mtp-sendfile is not installed.")
        }

        var uploaded = 0
        var failures: [String] = []

        for uploadFile in uploadFiles {
            let localURL = URL(fileURLWithPath: uploadFile.localPath)
            guard fileManager.fileExists(atPath: localURL.path), fileSize(at: localURL) > 0 else {
                failures.append(uploadFile.displayName)
                continue
            }

            do {
                if let sendTrackPath = tools.status.mtpSendTrackPath {
                    var arguments = ["-q"]
                    arguments.append(contentsOf: ["-t", uploadFile.metadata?.title ?? localURL.deletingPathExtension().lastPathComponent])
                    if let artist = uploadFile.metadata?.artist, !artist.isEmpty {
                        arguments.append(contentsOf: ["-a", artist])
                    }
                    if let album = uploadFile.metadata?.album, !album.isEmpty {
                        arguments.append(contentsOf: ["-l", album])
                    }
                    if let duration = uploadFile.metadata?.durationSeconds, duration.isFinite {
                        arguments.append(contentsOf: ["-d", String(Int(duration))])
                    }
                    arguments.append(contentsOf: [localURL.path, uploadFile.remotePath])
                    _ = try commands.run(executable: sendTrackPath, arguments: arguments, timeout: 600)
                } else if let sendFilePath = tools.status.mtpSendFilePath {
                    _ = try commands.run(executable: sendFilePath, arguments: [localURL.path, uploadFile.remotePath], timeout: 600)
                }
                uploaded += 1
            } catch {
                failures.append(uploadFile.displayName)
            }
        }

        return MTPHelperResponse(
            ok: failures.isEmpty,
            operationResult: DeviceFileOperationResult(
                completedCount: uploaded,
                failedItems: failures,
                message: resultMessage(action: "uploaded", count: uploaded, failures: failures.count)
            )
        )
    }

    private func delete(_ files: [DeviceFile]) throws -> MTPHelperResponse {
        guard let deleteFilePath = tools.status.mtpDeleteFilePath else {
            throw missing("mtp-delfile is not installed.")
        }

        var deleted = 0
        var failures: [String] = []

        for file in files {
            guard let objectID = file.objectID else {
                failures.append(file.name)
                continue
            }
            do {
                _ = try commands.run(executable: deleteFilePath, arguments: ["-n", objectID], timeout: 120)
                deleted += 1
            } catch {
                failures.append(file.name)
            }
        }

        return MTPHelperResponse(
            ok: failures.isEmpty,
            operationResult: DeviceFileOperationResult(
                completedCount: deleted,
                failedItems: failures,
                message: resultMessage(action: "deleted", count: deleted, failures: failures.count)
            )
        )
    }

    private func optionalOutput(toolPath: String?, timeout: TimeInterval) throws -> String? {
        guard let toolPath else { return nil }
        do {
            return try commands.run(executable: toolPath, arguments: [], timeout: timeout)
        } catch {
            if let helperError = error as? MTPHelperError, helperError.code == "no-device" || helperError.code == "device-busy" {
                throw helperError
            }
            return nil
        }
    }

    private func missing(_ message: String) -> MTPHelperError {
        MTPHelperError(
            code: "dependencies-missing",
            message: message,
            recoverySuggestion: "Install MTP support from Settings, then refresh."
        )
    }

    private func fileSize(at url: URL) -> Int64 {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
    }

    private func resultMessage(action: String, count: Int, failures: Int) -> String {
        if failures == 0 {
            return "\(count) file(s) \(action)."
        }
        return "\(count) file(s) \(action); \(failures) failed."
    }

    private func sanitizedFileName(_ name: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func uniqueURL(in folderURL: URL, preferredFileName: String) -> URL {
        let preferredURL = folderURL.appendingPathComponent(preferredFileName)
        if !fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidateURL = folderURL.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return folderURL.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }
}

private struct MTPToolLocator {
    let status: MTPToolStatus

    init(fileManager: FileManager = .default) {
        func path(_ name: String) -> String? {
            let searchPaths = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ]
            for directory in searchPaths {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url.path
                }
            }
            return nil
        }

        status = MTPToolStatus(
            mtpDetectPath: path("mtp-detect"),
            mtpTracksPath: path("mtp-tracks"),
            mtpFilesPath: path("mtp-files"),
            mtpPlaylistsPath: path("mtp-playlists"),
            mtpGetFilePath: path("mtp-getfile"),
            mtpDeleteFilePath: path("mtp-delfile"),
            mtpSendFilePath: path("mtp-sendfile"),
            mtpSendTrackPath: path("mtp-sendtr")
        )
    }
}

private final class CommandRunner {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8"
        ]) { _, new in new }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            throw MTPHelperError(code: "timeout", message: "The Garmin did not respond before the operation timed out.")
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            try MTPOutputParser.validateMTPOutput(output, allowNoPlaylists: true)
            throw MTPHelperError(code: "command-failed", message: output.trimmedMTPMessage)
        }

        try MTPOutputParser.validateMTPOutput(output, allowNoPlaylists: true)
        return output
    }
}

private extension String {
    var trimmedMTPMessage: String {
        let lines = split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.last ?? "MTP command failed."
    }
}
