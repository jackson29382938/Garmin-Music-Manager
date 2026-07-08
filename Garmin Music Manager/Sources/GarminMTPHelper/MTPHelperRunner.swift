import Foundation
import GarminMusicCore

/// Dispatches `MTPHelperRequest`s against a direct-libmtp session.
///
/// When `reuseSession` is true (serve mode), the same `MTPDirectSession` stays open
/// across requests so the app can list → plan → upload without re-opening USB.
/// Transient open/session errors drop the session and retry once with a fresh open.
final class MTPHelperRunner {
    private let fileManager: FileManager
    private let dependencyStatus: MTPToolStatus
    private let reuseSession: Bool
    private var session: MTPDirectSession?
    private var progressReporter: MTPProgressReporter?

    init(reuseSession: Bool, fileManager: FileManager = .default) {
        self.reuseSession = reuseSession
        self.fileManager = fileManager
        self.dependencyStatus = MTPDirectStatus.current(fileManager: fileManager)
    }

    func setProgressReporter(_ reporter: MTPProgressReporter?) {
        progressReporter = reporter
        session?.progressReporter = reporter
    }

    func closeSession() {
        session = nil
    }

    func handle(_ request: MTPHelperRequest) -> MTPHelperResponse {
        do {
            switch request.operation {
            case .status:
                return MTPHelperResponse(ok: true, dependencyStatus: dependencyStatus)
            case .detect:
                return try withSession { session in
                    MTPHelperResponse(
                        ok: true,
                        snapshot: session.detectionSnapshot(),
                        dependencyStatus: dependencyStatus
                    )
                }
            case .listMusic, .storageInfo:
                return try withSession { session in
                    MTPHelperResponse(
                        ok: true,
                        snapshot: try session.musicSnapshot(),
                        dependencyStatus: dependencyStatus
                    )
                }
            case .listStorageTree:
                return try withSession { session in
                    MTPHelperResponse(
                        ok: true,
                        snapshot: try session.storageSnapshot(),
                        dependencyStatus: dependencyStatus
                    )
                }
            case .download:
                return try withSession { session in
                    MTPHelperResponse(
                        ok: true,
                        operationResult: try session.download(request.files, to: request.destinationPath),
                        dependencyStatus: dependencyStatus
                    )
                }
            case .upload:
                return try withSession { session in
                    MTPHelperResponse(
                        ok: true,
                        operationResult: try session.upload(request.uploadFiles),
                        dependencyStatus: dependencyStatus
                    )
                }
            case .delete:
                return try withSession { session in
                    MTPHelperResponse(
                        ok: true,
                        operationResult: try session.delete(request.files),
                        dependencyStatus: dependencyStatus
                    )
                }
            case .move:
                throw MTPHelperError(
                    code: "unsupported-move",
                    message: "Direct in-place move is disabled for this Garmin MTP connection.",
                    recoverySuggestion: "Use Move Within Garmin; the app will copy, verify, then ask before deleting originals."
                )
            }
        } catch let error as MTPHelperError {
            if Self.shouldDropSession(for: error) {
                closeSession()
            }
            return MTPHelperResponse(ok: false, dependencyStatus: dependencyStatus, error: error)
        } catch {
            closeSession()
            return MTPHelperResponse(
                ok: false,
                dependencyStatus: dependencyStatus,
                error: MTPHelperError(code: "operation-failed", message: error.localizedDescription)
            )
        }
    }

    private func withSession<T>(_ body: (MTPDirectSession) throws -> T) throws -> T {
        if !reuseSession {
            let oneShot = try MTPDirectSession.open(fileManager: fileManager)
            oneShot.progressReporter = progressReporter
            return try body(oneShot)
        }

        do {
            let active = try existingOrOpenSession()
            active.progressReporter = progressReporter
            return try body(active)
        } catch {
            // Drop a half-dead session and retry once — common after USB glitches.
            closeSession()
            guard MTPRetryPolicy.isTransientError(error) || Self.isSessionDeath(error) else {
                throw error
            }
            let reopened = try existingOrOpenSession()
            reopened.progressReporter = progressReporter
            return try body(reopened)
        }
    }

    private func existingOrOpenSession() throws -> MTPDirectSession {
        if let session {
            return session
        }
        let opened = try MTPDirectSession.open(fileManager: fileManager)
        opened.progressReporter = progressReporter
        session = opened
        return opened
    }

    private static func shouldDropSession(for error: MTPHelperError) -> Bool {
        isSessionDeath(error) || MTPRetryPolicy.isTransientError(error)
    }

    private static func isSessionDeath(_ error: Error) -> Bool {
        if let helperError = error as? MTPHelperError {
            let code = helperError.code.lowercased()
            if code == "device-busy" || code == "no-device" || code == "list-failed"
                || code == "upload-failed" || code == "download-failed" || code == "delete-failed" {
                let detail = [helperError.message, helperError.diagnosticDetail ?? ""]
                    .joined(separator: " ")
                    .lowercased()
                return detail.contains("lost contact")
                    || detail.contains("connection reset")
                    || detail.contains("no device")
                    || detail.contains("unable to open")
                    || detail.contains("could not open")
                    || detail.contains("pipe error")
                    || detail.contains("i/o error")
                    || detail.contains("usb")
            }
        }
        return MTPRetryPolicy.isTransientError(error)
    }
}
