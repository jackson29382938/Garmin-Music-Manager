import XCTest
@testable import GarminMusicCore

final class MTPErrorTranslatorTests: XCTestCase {
    func testClaimInterfaceMapsToBusyWording() {
        let message = MTPErrorTranslator.friendlyMessage(for: [
            "LIBMTP libusb: Attempt to claim interface failed: usb_claim_interface() = -6"
        ])
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("Another app is using the Garmin"), "got: \(message!)")
    }

    func testObjectTooLargeMapsToStorageWording() {
        let message = MTPErrorTranslator.friendlyMessage(for: [
            "PTP_RC error: Object too large for storage"
        ])
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("not enough free space"), "got: \(message!)")
    }

    func testPipeErrorMapsToCableWording() {
        let message = MTPErrorTranslator.friendlyMessage(for: [
            "LIBMTP PANIC: pipe error while reading"
        ])
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("USB connection"), "got: \(message!)")
    }

    func testUnknownErrorReturnsNil() {
        XCTAssertNil(MTPErrorTranslator.friendlyMessage(for: ["some entirely novel failure"]))
        XCTAssertNil(MTPErrorTranslator.friendlyMessage(for: []))
    }

    // The retry policy must keep classifying transient failures even though raw
    // libmtp text now lives in diagnosticDetail instead of the message.
    func testRetryPolicyReadsDiagnosticDetail() {
        let translated = MTPHelperError(
            code: "delete-failed",
            message: "Could not delete Song.mp3 from the Garmin. Another app is using the Garmin.",
            diagnosticDetail: "usb_claim_interface() = -6, resource busy"
        )
        XCTAssertTrue(MTPRetryPolicy.isTransientError(translated))

        let permanent = MTPHelperError(
            code: "delete-failed",
            message: "Could not delete Song.mp3 from the Garmin.",
            diagnosticDetail: "no such object"
        )
        XCTAssertFalse(MTPRetryPolicy.isTransientError(permanent))
    }
}
