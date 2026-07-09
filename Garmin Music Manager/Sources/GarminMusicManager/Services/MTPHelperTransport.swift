import Foundation
import GarminMusicCore

/// Sends an encoded `MTPHelperRequest` payload and returns the helper's raw
/// **final** response bytes. Progress events are delivered via `onProgress`.
protocol MTPHelperTransport: Sendable {
    func send(
        _ requestData: Data,
        timeout: TimeInterval,
        onProgress: (@Sendable (MTPProgressEvent) -> Void)?
    ) async throws -> Data
}

extension MTPHelperTransport {
    func send(_ requestData: Data, timeout: TimeInterval) async throws -> Data {
        try await send(requestData, timeout: timeout, onProgress: nil)
    }
}

// MARK: - Persistent (long-lived) helper

/// Keeps a single `GarminMTPHelper --serve` process warm so list/upload/delete
/// share one MTP session. This is the primary production transport.
///
/// Framing: NDJSON on stdin/stdout — zero or more `{"progress":...}` lines,
/// then one final `{"ok":...}` response line.
actor PersistentMTPHelperTransport: MTPHelperTransport {
    let helperURL: URL
    private(set) var idleTimeout: TimeInterval = 90
    var defaultTimeoutFloor: TimeInterval = 15

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readBuffer = Data()
    private var lastUsed = Date.distantPast
    private var idleWorkItem: DispatchWorkItem?
    /// True while a request is in flight; cancel escalates SIGUSR1 → SIGTERM.
    private var inFlight = false
    private var cancelRequested = false

    init(helperURL: URL) {
        self.helperURL = helperURL
    }

    /// Updates keep-alive idle timeout (from Performance settings). Reschedules idle shutdown.
    func setIdleTimeout(_ seconds: TimeInterval) {
        idleTimeout = min(600, max(15, seconds))
        if process != nil {
            scheduleIdleShutdown()
        }
    }

    func send(
        _ requestData: Data,
        timeout: TimeInterval,
        onProgress: (@Sendable (MTPProgressEvent) -> Void)?
    ) async throws -> Data {
        try Task.checkCancellation()
        try ensureProcessRunning()

        var line = requestData
        if line.last != 0x0A {
            line.append(0x0A)
        }

        guard let stdinHandle else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper has no stdin pipe.")
        }

        inFlight = true
        cancelRequested = false
        defer { inFlight = false }

        do {
            try stdinHandle.write(contentsOf: line)
        } catch {
            restartProcess()
            throw DeviceFileSystemError.helperFailed(
                "Lost contact with the Garmin helper while sending a request. Retry."
            )
        }

        lastUsed = Date()
        scheduleIdleShutdown()

        let responseTimeout = max(timeout, defaultTimeoutFloor)
        do {
            let data = try await withTaskCancellationHandler {
                try await readUntilFinalResponse(timeout: responseTimeout, onProgress: onProgress)
            } onCancel: {
                Task { await self.requestCancel() }
            }
            if cancelRequested || Task.isCancelled {
                throw CancellationError()
            }
            lastUsed = Date()
            scheduleIdleShutdown()
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cancelRequested || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Cooperative mid-transfer cancel: SIGUSR1 asks the helper to abort the
    /// current libmtp call via its progress callback; escalates to SIGTERM if
    /// the process is still stuck shortly after.
    func requestCancel() {
        cancelRequested = true
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGUSR1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { [weak self] in
            Task { await self?.escalateCancelIfNeeded(pid: pid) }
        }
    }

    private func escalateCancelIfNeeded(pid: Int32) {
        guard cancelRequested, let process, process.isRunning,
              process.processIdentifier == pid else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    func shutdown() {
        cancelIdleShutdown()
        terminateProcess()
    }

    /// Abort any in-flight request without dropping the shared transport registration.
    func interrupt() {
        requestCancel()
        // Hard stop if nothing is marked in-flight (e.g. stuck open).
        if !inFlight {
            terminateProcess()
        }
    }

    // MARK: Process lifecycle

    private func ensureProcessRunning() throws {
        if let process, process.isRunning, stdinHandle != nil, stdoutHandle != nil {
            return
        }
        try startProcess()
    }

    private func startProcess() throws {
        terminateProcess()

        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--serve"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        self.process = process
        self.stdinHandle = inputPipe.fileHandleForWriting
        self.stdoutHandle = outputPipe.fileHandleForReading
        self.readBuffer = Data()
        self.lastUsed = Date()
    }

    private func restartProcess() {
        terminateProcess()
    }

    private func terminateProcess() {
        cancelIdleShutdown()
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        readBuffer = Data()
    }

    private func scheduleIdleShutdown() {
        cancelIdleShutdown()
        let timeout = idleTimeout
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.idleShutdownIfNeeded() }
        }
        idleWorkItem = work
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func cancelIdleShutdown() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
    }

    private func idleShutdownIfNeeded() {
        guard Date().timeIntervalSince(lastUsed) >= idleTimeout - 0.5 else {
            scheduleIdleShutdown()
            return
        }
        terminateProcess()
    }

    // MARK: Multi-line read (progress + final)

    private func readUntilFinalResponse(
        timeout: TimeInterval,
        onProgress: (@Sendable (MTPProgressEvent) -> Void)?
    ) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            try Task.checkCancellation()

            if Date() > deadline {
                restartProcess()
                throw DeviceFileSystemError.helperFailed("The Garmin helper timed out.")
            }

            if let line = popLineFromBuffer() {
                if let final = try Self.interpretLine(line, onProgress: onProgress) {
                    return final
                }
                // Progress only — keep reading.
                lastUsed = Date()
                continue
            }

            if let process, !process.isRunning {
                if let line = popLineFromBuffer(), let final = try Self.interpretLine(line, onProgress: onProgress) {
                    return final
                }
                restartProcess()
                if cancelRequested || Task.isCancelled {
                    throw CancellationError()
                }
                throw DeviceFileSystemError.helperFailed(
                    "The Garmin helper exited before producing a response."
                )
            }

            let remaining = deadline.timeIntervalSinceNow
            let chunk = try await readAvailable(timeout: min(0.5, max(0.05, remaining)))
            if chunk.isEmpty {
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            readBuffer.append(chunk)
        }
    }

    /// Returns final response data, or nil if the line was progress-only.
    private static func interpretLine(
        _ line: Data,
        onProgress: (@Sendable (MTPProgressEvent) -> Void)?
    ) throws -> Data? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let streamLine: MTPHelperStreamLine
        do {
            streamLine = try decoder.decode(MTPHelperStreamLine.self, from: line)
        } catch {
            // Final responses historically may not include optional progress keys;
            // raw line is still the final payload if it decodes as MTPHelperResponse.
            if (try? decoder.decode(MTPHelperResponse.self, from: line)) != nil {
                return line
            }
            let prefix = String(decoding: line.prefix(200), as: UTF8.self)
            throw DeviceFileSystemError.helperFailed(
                "The Garmin helper returned an unreadable response (output: \(prefix))."
            )
        }

        if streamLine.isProgressOnly, let progress = streamLine.progress {
            onProgress?(progress)
            return nil
        }
        if streamLine.asResponse != nil {
            return line
        }
        // Ambiguous but non-empty — treat as final.
        return line
    }

    private func popLineFromBuffer() -> Data? {
        guard let newline = readBuffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(readBuffer[..<newline])
        let next = readBuffer.index(after: newline)
        readBuffer = Data(readBuffer[next...])
        return line
    }

    private func readAvailable(timeout: TimeInterval) async throws -> Data {
        guard let stdoutHandle else { return Data() }
        _ = timeout
        let handle = stdoutHandle
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.availableData)
            }
        }
    }
}

// MARK: - One-shot subprocess (legacy / tests)

struct SubprocessMTPHelperTransport: MTPHelperTransport {
    let helperURL: URL

    func send(
        _ requestData: Data,
        timeout: TimeInterval,
        onProgress: (@Sendable (MTPProgressEvent) -> Void)?
    ) async throws -> Data {
        try Task.checkCancellation()
        let helperURL = self.helperURL
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.sendSync(
                    helperURL: helperURL,
                    requestData: requestData,
                    timeout: timeout,
                    box: box,
                    onProgress: onProgress
                )
            }.value
        } onCancel: {
            box.cancel()
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func register(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            guard let process else { return }
            Self.terminate(process)
        }

        static func terminate(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    private static func sendSync(
        helperURL: URL,
        requestData: Data,
        timeout: TimeInterval,
        box: ProcessBox,
        onProgress: (@Sendable (MTPProgressEvent) -> Void)?
    ) throws -> Data {
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = helperURL

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        guard !box.isCancelled else { throw CancellationError() }
        try process.run()
        box.register(process)
        if box.isCancelled {
            ProcessBox.terminate(process)
        }

        try? inputPipe.fileHandleForWriting.write(contentsOf: requestData)
        try? inputPipe.fileHandleForWriting.close()

        // Stream stdout while the process runs so progress arrives live.
        let stdout = outputPipe.fileHandleForReading
        var buffer = Data()
        var finalLine: Data?
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        while finalLine == nil {
            if box.isCancelled {
                // Cooperative cancel first so mid-file libmtp can abort cleanly.
                kill(process.processIdentifier, SIGUSR1)
                Thread.sleep(forTimeInterval: 0.4)
                if process.isRunning {
                    ProcessBox.terminate(process)
                }
                throw CancellationError()
            }
            if Date() > deadline {
                ProcessBox.terminate(process)
                throw DeviceFileSystemError.helperFailed("The Garmin helper timed out.")
            }

            let chunk = stdout.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                if line.isEmpty { continue }
                if let streamLine = try? decoder.decode(MTPHelperStreamLine.self, from: line),
                   streamLine.isProgressOnly,
                   let progress = streamLine.progress {
                    onProgress?(progress)
                    continue
                }
                // Final cancelled response still counts as a finished request.
                if let streamLine = try? decoder.decode(MTPHelperStreamLine.self, from: line),
                   streamLine.error?.code == "cancelled" {
                    throw CancellationError()
                }
                finalLine = line
                break
            }
        }

        if terminated.wait(timeout: .now() + 2) == .timedOut {
            process.waitUntilExit()
        }

        if box.isCancelled { throw CancellationError() }

        if let finalLine {
            return finalLine
        }

        // No newline framing (older helper): use remaining buffer.
        if !buffer.isEmpty {
            return buffer
        }

        if process.terminationStatus != 0 {
            throw DeviceFileSystemError.helperFailed(
                "The Garmin helper exited with status \(process.terminationStatus) before producing a response."
            )
        }
        throw DeviceFileSystemError.helperFailed(
            "The Garmin helper exited with status \(process.terminationStatus) before producing a response."
        )
    }
}
