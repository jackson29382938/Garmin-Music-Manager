import Foundation

public enum MTPRetryPolicy {
    public static let maxAttempts = 3
    public static let backoffSeconds: TimeInterval = 0.8

    public static func isTransientError(_ error: Error) -> Bool {
        let message: String
        if let helperError = error as? MTPHelperError {
            if helperError.code == "device-busy" || helperError.code == "timeout" {
                return true
            }
            // Raw libmtp text lives in diagnosticDetail; the message may be a
            // translated summary that no longer contains the raw markers.
            message = [helperError.message, helperError.diagnosticDetail ?? ""]
                .joined(separator: " ")
                .lowercased()
        } else {
            message = error.localizedDescription.lowercased()
        }

        return message.contains("could not open the usb connection")
            || message.contains("unable to open raw device")
            || message.contains("failed to open session")
            || message.contains("claim_interface")
            || message.contains("device is busy")
            || message.contains("resource busy")
            || message.contains("pipe error")
            || message.contains("connection reset")
            || message.contains("i/o error")
            || message.contains("libmtp error connecting")
            || message.contains("lost contact")
            || message.contains("timed out")
            || message.contains("timeout")
            || message.contains("temporarily unavailable")
            || message.contains("device disconnected")
            || message.contains("device not responding")
            || message.contains("usb transfer")
            || message.contains("stall")
    }

    public static func isTransientFailureMessage(_ message: String) -> Bool {
        isTransientError(MTPHelperError(code: "transient-check", message: message))
    }

    public static func runWithRetry<T>(_ operation: () throws -> T) throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try operation()
            } catch {
                lastError = error
                guard attempt < maxAttempts, isTransientError(error) else {
                    throw error
                }
                Thread.sleep(forTimeInterval: backoffSeconds * Double(attempt))
            }
        }
        throw lastError ?? MTPHelperError(code: "operation-failed", message: "MTP operation failed after retries.")
    }
}
