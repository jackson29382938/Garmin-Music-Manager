import Foundation
import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

final class PerformanceSettingsTests: XCTestCase {
    func testBalancedDefaultMatchesHistoricalTier() {
        let settings = PerformanceSettings.default
        XCTAssertEqual(settings.listingReuseSeconds, 120)
        XCTAssertEqual(settings.mtpSessionKeepAliveSeconds, 90)
        XCTAssertEqual(settings.uploadBatchSize, 5)
        XCTAssertTrue(settings.autoDetectDevices)
        XCTAssertEqual(settings.usbPollIntervalSeconds, 6)
        XCTAssertEqual(settings.aacBitrateKbps, 256)
        XCTAssertFalse(settings.forceRefreshBeforeSync)
        XCTAssertEqual(settings.mtpRetryAttempts, 3)
        XCTAssertEqual(settings.mtpRetryBackoffSeconds, 0.8, accuracy: 0.001)
        XCTAssertEqual(settings.operationTimeoutScale, 1.0, accuracy: 0.001)
        XCTAssertFalse(settings.compressLargeFiles)
        XCTAssertFalse(settings.includePlaylistContentsWhenBrowsing)
        XCTAssertTrue(settings.verifyUploads)
        XCTAssertEqual(settings.matchedPreset, .balanced)
    }

    func testNamedPresetsAreDistinctAndMatch() {
        for preset in PerformancePreset.allCases where preset != .custom {
            let settings = PerformanceSettings.template(for: preset).clamped
            XCTAssertEqual(
                PerformanceSettings.matchingPreset(for: settings),
                preset,
                "Template for \(preset) should match itself"
            )
        }
    }

    func testCustomWhenUserEditsBatch() {
        var settings = PerformanceSettings.template(for: .fast)
        settings.uploadBatchSize = 7
        settings.clamp()
        XCTAssertEqual(settings.matchedPreset, .custom)
    }

    func testClampEnforcesRanges() {
        var settings = PerformanceSettings.default
        settings.listingReuseSeconds = 9_999
        settings.uploadBatchSize = 0
        settings.mtpRetryAttempts = 99
        settings.operationTimeoutScale = 0.1
        settings.aacBitrateKbps = 10
        settings.clamp()
        XCTAssertEqual(settings.listingReuseSeconds, PerformanceSettings.listingReuseRange.upperBound)
        XCTAssertEqual(settings.uploadBatchSize, PerformanceSettings.uploadBatchRange.lowerBound)
        XCTAssertEqual(settings.mtpRetryAttempts, PerformanceSettings.retryAttemptsRange.upperBound)
        XCTAssertEqual(settings.operationTimeoutScale, PerformanceSettings.timeoutScaleRange.lowerBound)
        XCTAssertEqual(settings.aacBitrateKbps, PerformanceSettings.aacBitrateRange.lowerBound)
    }

    func testLargeFileThresholdNilWhenDisabled() {
        var settings = PerformanceSettings.default
        settings.compressLargeFiles = false
        settings.convertLargeFilesOverMB = 50
        XCTAssertNil(settings.largeFileByteThreshold)

        settings.compressLargeFiles = true
        XCTAssertEqual(settings.largeFileByteThreshold, 50 * 1_048_576)
    }

    func testSettingsStoreRoundTripTierB() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = SettingsStore(defaults: defaults)

        var custom = PerformanceSettings.template(for: .reliable)
        custom.includePlaylistContentsWhenBrowsing = true
        custom.operationTimeoutScale = 2.0
        store.performanceSettings = custom

        let loaded = store.performanceSettings
        XCTAssertTrue(loaded.forceRefreshBeforeSync)
        XCTAssertEqual(loaded.uploadBatchSize, 1)
        XCTAssertEqual(loaded.mtpRetryAttempts, 5)
        XCTAssertTrue(loaded.includePlaylistContentsWhenBrowsing)
        XCTAssertEqual(loaded.operationTimeoutScale, 2.0, accuracy: 0.001)
        XCTAssertEqual(loaded.matchedPreset, .custom) // includePlaylistContents differs from reliable
    }

    func testMissingKeysLoadBalancedDefaults() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.performanceSettings, .default)
    }

    func testResetAppStateKeepsPerformance() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = SettingsStore(defaults: defaults)
        store.performanceSettings = .template(for: .fast)
        store.destinationMode = .customFolder
        store.saveDestination(URL(fileURLWithPath: "/tmp/x", isDirectory: true))
        store.resetAppState()
        XCTAssertEqual(store.destinationMode, .autoDetected)
        XCTAssertEqual(store.performanceSettings.matchedPreset, .fast)
    }

    func testResetAllSettingsClearsPerformance() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = SettingsStore(defaults: defaults)
        store.performanceSettings = .template(for: .fast)
        store.resetAllSettings()
        XCTAssertEqual(store.performanceSettings, .default)
    }

    func testApplyPresetIgnoresCustom() {
        var settings = PerformanceSettings.template(for: .fast)
        settings.applyPreset(.custom)
        XCTAssertEqual(settings.matchedPreset, .fast)
    }
}

@MainActor
final class DeviceBrowserListingReuseTests: XCTestCase {
    func testZeroTTLNeverReportsFreshListing() {
        let store = DeviceBrowserStore()
        store.listingReuseTTL = 0
        XCTAssertFalse(store.hasFreshListing)
    }

    func testDefaultTTLMatchesHistorical() {
        XCTAssertEqual(DeviceBrowserStore.defaultListingReuseTTL, 120)
        let store = DeviceBrowserStore()
        XCTAssertEqual(store.listingReuseTTL, 120)
    }
}

@MainActor
final class SyncCoordinatorLargeFilePrepTests: XCTestCase {
    func testCompressLargeFilesWithoutFormatConvertToggle() {
        let coordinator = SyncCoordinator()
        var settings = SyncSettings.default
        settings.convertIncompatibleFormats = false
        var performance = PerformanceSettings.default
        performance.compressLargeFiles = true
        performance.convertLargeFilesOverMB = 1

        let huge = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/huge.mp3"),
            fileName: "huge.mp3",
            fileExtension: "mp3",
            title: "Huge",
            artist: "A",
            album: nil,
            durationSeconds: 300,
            byteCount: 5_000_000,
            codecHint: "mp3",
            compatibility: .ready,
            isSelected: true
        )

        let result = coordinator.prepareTracks([huge], settings: settings, performance: performance)
        // Without ffmpeg we still report a failure rather than silent skip.
        if result.convertedCount == 0 {
            XCTAssertFalse(result.conversionFailures.isEmpty)
        } else {
            XCTAssertEqual(result.tracks[0].fileExtension, "m4a")
        }
    }
}

final class MTPHelperRequestVerifyFlagTests: XCTestCase {
    func testVerifyUploadsDefaultsTrueAndRoundTrips() throws {
        let request = MTPHelperRequest(operation: .upload, uploadFiles: [])
        XCTAssertTrue(request.verifyUploads)

        var encoded = request
        encoded.verifyUploads = false
        let data = try JSONEncoder().encode(encoded)
        let decoded = try JSONDecoder().decode(MTPHelperRequest.self, from: data)
        XCTAssertFalse(decoded.verifyUploads)
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "GarminMusicManagerTests.Perf.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Could not create isolated UserDefaults suite.")
    }
    defaults.set(suiteName, forKey: "__suiteName")
    return defaults
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "__suiteName") ?? ""
}
