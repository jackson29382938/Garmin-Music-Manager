import Foundation

actor MTPOperationCoordinator {
    static let shared = MTPOperationCoordinator()

    private var isRunning = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelledIDs: Set<UUID> = []

    func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isRunning {
            isRunning = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func enqueue(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        // Cancellation can race ahead of registration.
        if cancelledIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        // The lock may have been released while this waiter was suspending.
        if !isRunning {
            isRunning = true
            continuation.resume()
            return
        }
        waiters.append((id: id, continuation: continuation))
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            // Not registered yet (or already resumed; the stale ID is harmless).
            cancelledIDs.insert(id)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
