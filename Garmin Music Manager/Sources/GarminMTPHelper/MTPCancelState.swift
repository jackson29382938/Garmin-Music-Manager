import Darwin
import Foundation
import GarminMusicCore

/// Cooperative cancel flag for in-flight libmtp transfers.
///
/// Set by `SIGUSR1` (preferred — keeps the process alive) or `SIGTERM`/`SIGINT`.
/// The libmtp progress callback returns non-zero when this is set so the current
/// file transfer aborts without waiting for the full USB write to finish.
enum MTPCancelState {
    private static let lock = NSLock()
    private static var _cancelled = false
    private static var handlersInstalled = false

    static var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    static func requestCancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        _cancelled = false
        lock.unlock()
    }

    static func throwIfCancelled() throws {
        if isCancelled {
            throw MTPHelperError(
                code: "cancelled",
                message: "Transfer cancelled.",
                recoverySuggestion: "Start the transfer again when you are ready."
            )
        }
    }

    /// Install once at process start. Safe to call repeatedly.
    static func installSignalHandlers() {
        lock.lock()
        defer { lock.unlock() }
        guard !handlersInstalled else { return }
        handlersInstalled = true

        // SIGUSR1: cooperative cancel from the app (do not exit).
        signal(SIGUSR1) { _ in
            MTPCancelState.requestCancel()
        }
        // SIGTERM/SIGINT: mark cancelled so progress callbacks abort ASAP,
        // then restore default and re-raise so the process still exits.
        signal(SIGTERM) { _ in
            MTPCancelState.requestCancel()
            signal(SIGTERM, SIG_DFL)
            raise(SIGTERM)
        }
        signal(SIGINT) { _ in
            MTPCancelState.requestCancel()
            signal(SIGINT, SIG_DFL)
            raise(SIGINT)
        }
    }
}
