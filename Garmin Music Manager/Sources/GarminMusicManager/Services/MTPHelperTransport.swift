import Foundation

/// Sends an encoded `MTPHelperRequest` payload and returns the helper's raw
/// response bytes. Abstracted so `MTPHelperClient` logic is testable without
/// spawning the real helper subprocess.
protocol MTPHelperTransport: Sendable {
    func send(_ requestData: Data, timeout: TimeInterval) async throws -> Data
}

// MARK: - Persistent (long-lived) helper

/// Keeps a single `GarminMTPHelper --serve` process warm so list/upload/delete
/// share one MTP session. This is the primary production transport.
///
/// Framing: one JSON object per line (NDJSON) on stdin/stdout of the helper.
/// The process is restarted after crashes, idle timeout, or a broken pipe.
actor PersistentMTPHelperTransport: MTPHelperTransport {
    let helperURL: URL
    /// Release the USB device when the app has been idle this long.
    var idleTimeout: TimeInterval = 90
    /// Hard ceiling for how long a single request may wait for a response line.
    var defaultTimeoutFloor: TimeInterval = 15

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readBuffer = Data()
    private var lastUsed = Date.distantPast
    private var idleWorkItem: DispatchWorkItem?

    init(helperURL: URL) {
        self.helperURL = helperURL
    }

    // Note: no deinit cleanup — actor-isolated process handles cannot be
    // touched from deinit. Call `shutdown()` from app reset / terminate, and
    // rely on idle timeout + process exit otherwise.

    func send(_ requestData: Data, timeout: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        try ensureProcessRunning()

        // Write one request line.
        var line = requestData
        if line.last != 0x0A {
            line.append(0x0A)
        }

        guard let stdinHandle else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper has no stdin pipe.")
        }

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
        let data = try await readResponseLine(timeout: responseTimeout)
        lastUsed = Date()
        scheduleIdleShutdown()
        return data
    }

    /// Force-stop the helper (e.g. on app reset or user cancel of all MTP work).
    func shutdown() {
        cancelIdleShutdown()
        terminateProcess()
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

    // MARK: Line reading

    private func readResponseLine(timeout: TimeInterval) async throws -> Data {
        if let line = popLineFromBuffer() {
            return line
        }

        guard let stdoutHandle else {
            throw DeviceFileSystemError.helperFailed("The Garmin helper has no stdout pipe.")
        }

        let handle = stdoutHandle
        let bufferBox = BufferBox(readBuffer)
        // Clear actor-owned buffer; the worker owns the in-flight remainder.
        readBuffer = Data()

        do {
            let (line, remainder) = try await withThrowingTaskGroup(of: (Data, Data).self) { group in
                group.addTask {
                    try Self.readLineBlocking(from: handle, initial: bufferBox.data)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw DeviceFileSystemError.helperFailed("The Garmin helper timed out.")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            readBuffer = remainder
            return line
        } catch {
            // Pull back any partial bytes the worker may have collected.
            readBuffer = bufferBox.data
            if (error as? DeviceFileSystemError).map({
                if case .helperFailed(let message) = $0 { return message.contains("timed out") }
                return false
            }) ?? false {
                restartProcess()
            } else if let process, !process.isRunning {
                restartProcess()
            }
            throw error
        }
    }

    private func popLineFromBuffer() -> Data? {
        guard let newline = readBuffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(readBuffer[..<newline])
        let next = readBuffer.index(after: newline)
        readBuffer = Data(readBuffer[next...])
        return line
    }

    /// Reads bytes until a newline, returning (lineWithoutNewline, leftoverAfterNewline).
    private static func readLineBlocking(from handle: FileHandle, initial: Data) throws -> (Data, Data) {
        var buffer = initial
        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            let next = buffer.index(after: newline)
            return (line, Data(buffer[next...]))
        }

        while true {
            try Task.checkCancellation()
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF or transient empty. If we have no newline yet, treat as failure.
                if buffer.isEmpty {
                    throw DeviceFileSystemError.helperFailed(
                        "The Garmin helper exited before producing a response."
                    )
                }
                // Return partial as line (one-shot style compatibility).
                return (buffer, Data())
            }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                let next = buffer.index(after: newline)
                return (line, Data(buffer[next...]))
            }
            if buffer.count > 32 * 1_024 * 1_024 {
                throw DeviceFileSystemError.helperFailed("The Garmin helper response exceeded 32 MB.")
            }
        }
    }

    /// Tiny box so the blocking reader and actor can hand off buffer ownership.
    private final class BufferBox: @unchecked Sendable {
        var data: Data
        init(_ data: Data) { self.data = data }
    }
}

// MARK: - One-shot subprocess (legacy / tests)

/// Runs the bundled `GarminMTPHelper` executable once per request.
/// Kept for fallback and for cancellation tests that expect a short-lived process.
struct SubprocessMTPHelperTransport: MTPHelperTransport {
    let helperURL: URL

    func send(_ requestData: Data, timeout: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        let helperURL = self.helperURL
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.sendSync(helperURL: helperURL, requestData: requestData, timeout: timeout, box: box)
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

    private static func sendSync(helperURL: URL, requestData: Data, timeout: TimeInterval, box: ProcessBox) throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarminMTPHelper-\(UUID().uuidString).json")
        FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
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

        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 2)
            }
            throw DeviceFileSystemError.helperFailed("The Garmin helper timed out.")
        }

        process.waitUntilExit()

        if box.isCancelled {
            throw CancellationError()
        }

        try outputHandle.synchronize()
        let data = try Data(contentsOf: outputURL)

        if data.isEmpty, process.terminationStatus != 0 {
            throw DeviceFileSystemError.helperFailed(
                "The Garmin helper exited with status \(process.terminationStatus) before producing a response."
            )
        }
        return data
    }
}
