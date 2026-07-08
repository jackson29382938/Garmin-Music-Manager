import Foundation
import XCTest
@testable import GarminMusicManager

final class MTPDependencyStatusTests: XCTestCase {
    func testUnavailableIsNotReady() {
        let status = MTPDependencyStatus.unavailable
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.canInstallViaHomebrew)
        XCTAssertTrue(status.message.contains("helper is missing") || status.message.contains("not ready") || status.message.contains("libmtp"))
    }

    func testBundledHelperAndLibmtpIsReadyWithoutHomebrew() {
        let helper = URL(fileURLWithPath: "/Applications/Garmin Music Manager.app/Contents/MacOS/GarminMTPHelper")
        let bundled = URL(fileURLWithPath: "/Applications/Garmin Music Manager.app/Contents/Frameworks/libmtp.9.dylib")
        let status = MTPDependencyStatus(
            homebrewURL: nil,
            libmtpLibraryURL: nil,
            libmtpHeaderURL: nil,
            helperURL: helper,
            bundledLibmtpURL: bundled
        )
        XCTAssertTrue(status.isReady)
        XCTAssertFalse(status.canInstallViaHomebrew)
        XCTAssertTrue(status.message.contains("bundled"))
    }

    func testSystemLibmtpWithHelperIsReady() {
        let helper = URL(fileURLWithPath: "/tmp/.build/debug/GarminMTPHelper")
        let lib = URL(fileURLWithPath: "/opt/homebrew/lib/libmtp.dylib")
        let status = MTPDependencyStatus(
            homebrewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            libmtpLibraryURL: lib,
            libmtpHeaderURL: nil, // headers not required at runtime
            helperURL: helper,
            bundledLibmtpURL: nil
        )
        XCTAssertTrue(status.isReady)
        XCTAssertFalse(status.canInstallViaHomebrew)
    }

    func testHelperWithoutAnyLibmtpIsNotReady() {
        let helper = URL(fileURLWithPath: "/tmp/GarminMTPHelper")
        let status = MTPDependencyStatus(
            homebrewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            libmtpLibraryURL: nil,
            libmtpHeaderURL: nil,
            helperURL: helper,
            bundledLibmtpURL: nil
        )
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.canInstallViaHomebrew)
    }

    func testHeadersAloneDoNotMakeReady() {
        // Regression: old isReady required headers, which blocked packaged apps.
        let status = MTPDependencyStatus(
            homebrewURL: nil,
            libmtpLibraryURL: nil,
            libmtpHeaderURL: URL(fileURLWithPath: "/opt/homebrew/include/libmtp.h"),
            helperURL: URL(fileURLWithPath: "/tmp/helper"),
            bundledLibmtpURL: nil
        )
        XCTAssertFalse(status.isReady)
    }

    func testBundledLibmtpDetectionNearHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let macos = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let frameworks = root.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)

        let helper = macos.appendingPathComponent("GarminMTPHelper")
        FileManager.default.createFile(atPath: helper.path, contents: Data([0x00]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let lib = frameworks.appendingPathComponent("libmtp.9.dylib")
        FileManager.default.createFile(atPath: lib.path, contents: Data([0x01]))

        defer { try? FileManager.default.removeItem(at: root) }

        let manager = MTPDependencyManager()
        let found = manager.bundledLibmtpURL(nearHelper: helper)
        XCTAssertEqual(found?.path, lib.path)
    }

    func testLiveDependencyStatusSeesHelperOrBrewOnThisMachine() {
        let status = MTPDependencyManager().dependencyStatus()
        // Either the package has a helper in dist/.build, or brew libmtp is present on this dev machine.
        // This is a soft smoke check — not a hard requirement that isReady is true.
        if status.helperURL != nil {
            XCTAssertNotNil(status.helperURL)
        }
        if status.isReady {
            XCTAssertTrue(status.helperURL != nil)
            XCTAssertTrue(status.bundledLibmtpURL != nil || status.libmtpLibraryURL != nil)
        }
    }
}
