import Foundation
import GarminMusicCore

protocol DeviceFileSystem {
    var deviceID: String { get }
    var displayName: String { get }
    var backendKind: DeviceBackendKind { get }
    var supportsMove: Bool { get }

    func listMusic() async throws -> DeviceFileSystemSnapshot
    func listStorageTree() async throws -> DeviceFileSystemSnapshot
    func download(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult
    func upload(_ files: [DeviceUploadFile]) async throws -> DeviceFileOperationResult
    func delete(_ files: [DeviceFile]) async throws -> DeviceFileOperationResult
    func move(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult
    func storageInfo() async throws -> DeviceStorageInfo?
}

enum DeviceFileSystemError: LocalizedError {
    case helperMissing
    case helperFailed(String)
    case unsupported(String)
    case missingDestination
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The bundled Garmin helper is missing. Rebuild the app bundle and try again."
        case .helperFailed(let message):
            return message
        case .unsupported(let message):
            return message
        case .missingDestination:
            return "Choose a destination folder first."
        case .verificationFailed(let message):
            return message
        }
    }
}

final class MountedFolderDeviceFileSystem: DeviceFileSystem {
    let deviceID: String
    let displayName: String
    let backendKind: DeviceBackendKind = .mountedFolder
    let supportsMove = true

    private let rootURL: URL
    private let fileManager: FileManager
    private let audioExtensions = MusicScanner.supportedAudioExtensions
    private let playlistExtensions = MusicScanner.supportedPlaylistExtensions

    init(rootURL: URL, displayName: String? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.displayName = displayName ?? rootURL.lastPathComponent
        self.deviceID = "mounted:\(rootURL.path)"
        self.fileManager = fileManager
    }

    func listMusic() async throws -> DeviceFileSystemSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let files = try self.listFiles(includeAllFiles: false)
            return DeviceFileSystemSnapshot(
                files: files,
                collections: self.collections(for: files, includeFolders: true),
                storageInfo: self.storageInfoSync(for: files),
                deviceName: self.displayName,
                diagnosticMessage: files.isEmpty ? "No compatible audio files were found in this folder." : nil
            )
        }.value
    }

    func listStorageTree() async throws -> DeviceFileSystemSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let files = try self.listFiles(includeAllFiles: true)
            return DeviceFileSystemSnapshot(
                files: files,
                collections: [
                    DeviceCollection(id: "all-storage", name: "All Storage", kind: .folder, fileIDs: files.map(\.id))
                ],
                storageInfo: self.storageInfoSync(for: files),
                deviceName: self.displayName,
                diagnosticMessage: nil
            )
        }.value
    }

    func download(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult {
        try await Task.detached(priority: .userInitiated) {
            try self.fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            var copied = 0
            var failures: [String] = []

            for file in files {
                do {
                    let source = self.url(for: file)
                    let target = FileNameSanitizer.uniqueURL(
                        in: destinationFolder,
                        preferredFileName: FileNameSanitizer.sanitizeFileName(file.name, fallback: "Garmin File")
                    )
                    try self.fileManager.copyItem(at: source, to: target)
                    try self.verifyCopy(source: source, target: target)
                    copied += 1
                } catch {
                    failures.append(file.name)
                }
            }

            return DeviceFileOperationResult(
                completedCount: copied,
                failedItems: failures,
                message: self.resultMessage(action: "copied", count: copied, failures: failures.count)
            )
        }.value
    }

    func upload(_ files: [DeviceUploadFile]) async throws -> DeviceFileOperationResult {
        await Task.detached(priority: .userInitiated) {
            var copied = 0
            var failures: [String] = []

            for file in files {
                do {
                    let source = URL(fileURLWithPath: file.localPath)
                    let relativePath = file.remotePath.isEmpty ? source.lastPathComponent : file.remotePath
                    let target = self.rootURL.appendingPathComponent(relativePath)
                    try self.fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let finalTarget = self.fileManager.fileExists(atPath: target.path)
                        ? FileNameSanitizer.uniqueURL(in: target.deletingLastPathComponent(), preferredFileName: target.lastPathComponent)
                        : target
                    try self.fileManager.copyItem(at: source, to: finalTarget)
                    try self.verifyCopy(source: source, target: finalTarget)
                    copied += 1
                } catch {
                    failures.append(file.displayName)
                }
            }

            return DeviceFileOperationResult(
                completedCount: copied,
                failedItems: failures,
                message: self.resultMessage(action: "uploaded", count: copied, failures: failures.count)
            )
        }.value
    }

    func delete(_ files: [DeviceFile]) async throws -> DeviceFileOperationResult {
        await Task.detached(priority: .userInitiated) {
            var deleted = 0
            var failures: [String] = []

            for file in files {
                do {
                    let source = self.url(for: file)
                    if self.fileManager.fileExists(atPath: source.path) {
                        try self.fileManager.removeItem(at: source)
                        deleted += 1
                    }
                } catch {
                    failures.append(file.name)
                }
            }

            return DeviceFileOperationResult(
                completedCount: deleted,
                failedItems: failures,
                message: self.resultMessage(action: "deleted", count: deleted, failures: failures.count)
            )
        }.value
    }

    func move(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult {
        try await Task.detached(priority: .userInitiated) {
            try self.fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            var moved = 0
            var failures: [String] = []

            for file in files {
                do {
                    let source = self.url(for: file)
                    let target = FileNameSanitizer.uniqueURL(
                        in: destinationFolder,
                        preferredFileName: FileNameSanitizer.sanitizeFileName(file.name, fallback: "Garmin File")
                    )
                    let expectedSize = self.fileSize(at: source)
                    try self.fileManager.moveItem(at: source, to: target)
                    guard self.fileManager.fileExists(atPath: target.path), self.fileSize(at: target) == expectedSize else {
                        throw DeviceFileSystemError.verificationFailed("Move verification failed for \(file.name).")
                    }
                    moved += 1
                } catch {
                    failures.append(file.name)
                }
            }

            return DeviceFileOperationResult(
                completedCount: moved,
                failedItems: failures,
                message: self.resultMessage(action: "moved", count: moved, failures: failures.count)
            )
        }.value
    }

    func storageInfo() async throws -> DeviceStorageInfo? {
        try await Task.detached(priority: .userInitiated) {
            self.storageInfoSync(for: try self.listFiles(includeAllFiles: false))
        }.value
    }

    private func listFiles(includeAllFiles: Bool) throws -> [DeviceFile] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [DeviceFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]) else {
                continue
            }
            let type = fileType(for: url, isDirectory: values.isDirectory == true)
            if !includeAllFiles, type != .audio {
                continue
            }

            files.append(DeviceFile(
                objectID: nil,
                name: url.lastPathComponent,
                type: type,
                size: Int64(values.fileSize ?? 0),
                parentID: nil,
                path: relativePath(for: url),
                backendKind: .mountedFolder,
                modifiedDate: values.contentModificationDate,
                audioMetadata: nil
            ))
        }

        return files.sorted {
            if $0.type == .folder, $1.type != .folder { return true }
            if $0.type != .folder, $1.type == .folder { return false }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func collections(for files: [DeviceFile], includeFolders: Bool) -> [DeviceCollection] {
        var collections = [
            DeviceCollection(id: "all-music", name: "All Music", kind: .allMusic, fileIDs: files.map(\.id))
        ]

        guard includeFolders else { return collections }

        let grouped = Dictionary(grouping: files) { file in
            let parent = (file.path as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }

        for (folder, folderFiles) in grouped.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            guard !folder.isEmpty else { continue }
            collections.append(DeviceCollection(
                id: "folder:\(folder)",
                name: (folder as NSString).lastPathComponent,
                kind: .folder,
                fileIDs: folderFiles.map(\.id)
            ))
        }

        return collections
    }

    private func storageInfoSync(for files: [DeviceFile]) -> DeviceStorageInfo {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        let values = try? rootURL.resourceValues(forKeys: keys)
        return DeviceStorageInfo(
            totalCapacity: values?.volumeTotalCapacity.map { Int64($0) },
            availableCapacity: values?.volumeAvailableCapacityForImportantUsage.map { Int64($0) },
            usedByFiles: files.reduce(Int64(0)) { $0 + max($1.size, 0) },
            fileCount: files.count
        )
    }

    private func fileType(for url: URL, isDirectory: Bool) -> DeviceFileType {
        if isDirectory { return .folder }
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if playlistExtensions.contains(ext) { return .playlist }
        return .other
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    private func url(for file: DeviceFile) -> URL {
        rootURL.appendingPathComponent(file.path)
    }

    private func verifyCopy(source: URL, target: URL) throws {
        guard fileManager.fileExists(atPath: target.path) else {
            throw DeviceFileSystemError.verificationFailed("Copy finished but no destination file was created.")
        }
        guard fileSize(at: source) == fileSize(at: target) else {
            throw DeviceFileSystemError.verificationFailed("Copy verification failed because file sizes did not match.")
        }
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
}

final class MTPDeviceFileSystem: DeviceFileSystem {
    let deviceID: String
    let displayName: String
    let backendKind: DeviceBackendKind = .mtp
    let supportsMove = false

    private let helperClient: MTPHelperClient

    init(deviceID: String, displayName: String, helperClient: MTPHelperClient = MTPHelperClient()) {
        self.deviceID = "mtp:\(deviceID)"
        self.displayName = displayName
        self.helperClient = helperClient
    }

    func listMusic() async throws -> DeviceFileSystemSnapshot {
        try await helperClient.snapshot(request: MTPHelperRequest(operation: .listMusic, browseMode: .musicOnly))
    }

    func listStorageTree() async throws -> DeviceFileSystemSnapshot {
        try await helperClient.snapshot(request: MTPHelperRequest(operation: .listStorageTree, browseMode: .advancedStorage))
    }

    func download(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult {
        try await helperClient.operationResult(request: MTPHelperRequest(
            operation: .download,
            files: files,
            destinationPath: destinationFolder.path
        ))
    }

    func upload(_ files: [DeviceUploadFile]) async throws -> DeviceFileOperationResult {
        try await helperClient.operationResult(request: MTPHelperRequest(operation: .upload, uploadFiles: files))
    }

    func delete(_ files: [DeviceFile]) async throws -> DeviceFileOperationResult {
        try await helperClient.operationResult(request: MTPHelperRequest(operation: .delete, files: files))
    }

    func move(_ files: [DeviceFile], to destinationFolder: URL) async throws -> DeviceFileOperationResult {
        throw DeviceFileSystemError.unsupported("Move is disabled for this Garmin MTP connection. Copy to Mac, delete, or re-sync to a different playlist/folder instead.")
    }

    func storageInfo() async throws -> DeviceStorageInfo? {
        try await listMusic().storageInfo
    }
}

final class MTPHelperClient {
    private let helperURL: URL?

    init(helperURL: URL? = nil) {
        self.helperURL = helperURL ?? Self.locateHelper()
    }

    func snapshot(request: MTPHelperRequest) async throws -> DeviceFileSystemSnapshot {
        let response = try await perform(request: request, timeout: request.operation == .listStorageTree ? 220 : 120)
        guard let snapshot = response.snapshot else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper did not return device files.")
        }
        return snapshot
    }

    func operationResult(request: MTPHelperRequest) async throws -> DeviceFileOperationResult {
        let response = try await perform(request: request, timeout: 900)
        guard let result = response.operationResult else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper did not return an operation result.")
        }
        if !response.ok, result.completedCount == 0 {
            throw DeviceFileSystemError.helperFailed(result.message ?? "The Garmin operation failed.")
        }
        return result
    }

    func status() async throws -> MTPToolStatus {
        let response = try await perform(request: MTPHelperRequest(operation: .status), timeout: 15)
        guard let status = response.dependencyStatus else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper did not return diagnostics.")
        }
        return status
    }

    private func perform(request: MTPHelperRequest, timeout: TimeInterval) async throws -> MTPHelperResponse {
        guard let helperURL else {
            throw DeviceFileSystemError.helperMissing
        }

        return try await Task.detached(priority: .userInitiated) {
            try Self.performSync(helperURL: helperURL, request: request, timeout: timeout)
        }.value
    }

    private static func performSync(helperURL: URL, request: MTPHelperRequest, timeout: TimeInterval) throws -> MTPHelperResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let requestData = try encoder.encode(request)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarminMTPHelper-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = helperURL

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        try process.run()
        inputPipe.fileHandleForWriting.write(requestData)
        try? inputPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            throw DeviceFileSystemError.helperFailed("The Garmin helper timed out.")
        }

        try outputHandle.synchronize()
        let data = try Data(contentsOf: outputURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(MTPHelperResponse.self, from: data)
        if !response.ok, let error = response.error {
            throw DeviceFileSystemError.helperFailed(error.localizedDescription)
        }
        return response
    }

    private static func locateHelper() -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "GarminMTPHelper") {
            return bundled
        }

        var candidates: [URL] = []
        if let executableURL = Bundle.main.executableURL {
            let directory = executableURL.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("GarminMTPHelper"))
            candidates.append(directory.deletingLastPathComponent().appendingPathComponent("GarminMTPHelper"))
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(currentDirectory.appendingPathComponent(".build/debug/GarminMTPHelper"))
        candidates.append(currentDirectory.appendingPathComponent(".build/release/GarminMTPHelper"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
