import XCTest
@testable import GarminMusicManager

final class MTPOperationCoordinatorTests: XCTestCase {
    func testOperationsRunSerially() async throws {
        let coordinator = MTPOperationCoordinator()
        let gate = AsyncGate()
        let log = EventLog()

        let first = Task {
            try await coordinator.perform {
                await log.append("first-start")
                await gate.wait()
                await log.append("first-end")
            }
        }
        // Give the first operation time to acquire the lock.
        await log.waitForCount(1)

        let second = Task {
            try await coordinator.perform {
                await log.append("second")
            }
        }

        // The second operation must stay queued until the first releases.
        try await Task.sleep(nanoseconds: 100_000_000)
        let midway = await log.events
        XCTAssertEqual(midway, ["first-start"])

        await gate.open()
        try await first.value
        try await second.value

        let events = await log.events
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
    }

    func testCancellingQueuedWaiterThrowsAndReleasesNothing() async throws {
        let coordinator = MTPOperationCoordinator()
        let gate = AsyncGate()
        let log = EventLog()

        let first = Task {
            try await coordinator.perform {
                await log.append("first-start")
                await gate.wait()
            }
        }
        await log.waitForCount(1)

        let queued = Task {
            try await coordinator.perform {
                await log.append("queued-ran")
            }
        }
        // Let the queued operation reach the waiter list before cancelling.
        try await Task.sleep(nanoseconds: 100_000_000)
        queued.cancel()

        do {
            try await queued.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        // The first operation still holds the lock and completes normally.
        await gate.open()
        try await first.value

        // A subsequent operation acquires the lock — nothing leaked.
        try await coordinator.perform {
            await log.append("third")
        }

        let events = await log.events
        XCTAssertEqual(events, ["first-start", "third"])
    }

    func testCancellationBeforeAcquireThrowsPromptly() async throws {
        let coordinator = MTPOperationCoordinator()
        let task = Task {
            // Cancelled before perform is reached.
            try await Task.sleep(nanoseconds: 200_000_000)
            return try await coordinator.perform { true }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        // Lock unaffected.
        let ran = try await coordinator.perform { true }
        XCTAssertTrue(ran)
    }
}

final class MTPHelperTransportCancellationTests: XCTestCase {
    func testCancellingSendTerminatesHelperProcess() async throws {
        // A stand-in "helper" that ignores stdin and sleeps far past the test timeout.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-garmin-helper-\(UUID().uuidString).sh")
        try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let transport = SubprocessMTPHelperTransport(helperURL: script)
        let started = Date()
        let task = Task {
            try await transport.send(Data("{}".utf8), timeout: 60)
        }

        // Let the subprocess launch, then cancel.
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected an error after cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "cancellation must not wait out the sleep")
    }

    func testHelperExitingWithoutOutputThrowsStatusError() async throws {
        let transport = SubprocessMTPHelperTransport(helperURL: URL(fileURLWithPath: "/usr/bin/false"))
        do {
            _ = try await transport.send(Data("{}".utf8), timeout: 30)
            XCTFail("Expected an error")
        } catch let error as DeviceFileSystemError {
            guard case .helperFailed(let message) = error else {
                return XCTFail("Unexpected error case: \(error)")
            }
            XCTAssertTrue(message.contains("exited with status"), "got: \(message)")
        }
    }
}

// MARK: - Test helpers

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor EventLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func waitForCount(_ count: Int) async {
        while events.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
