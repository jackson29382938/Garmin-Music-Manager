import XCTest
@testable import GarminMusicCore
@testable import GarminMusicManager

@MainActor
final class GuidedTransferPlanTests: XCTestCase {
    private func readyTrack(
        name: String,
        title: String? = nil,
        artist: String? = nil,
        size: Int64 = 5000,
        selected: Bool = true,
        duplicate: Bool = false
    ) -> AudioTrack {
        AudioTrack(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            fileName: name,
            fileExtension: "mp3",
            title: title ?? name,
            artist: artist,
            album: nil,
            durationSeconds: 200,
            byteCount: size,
            codecHint: "mp3",
            compatibility: .ready,
            isSelected: selected,
            isDuplicateOnDevice: duplicate
        )
    }

    func testBuildPlanToWatchClassifiesDuplicatesAndBlocked() {
        let defaults = UserDefaults(suiteName: "GuidedPlan.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let model = AppModel(settingsStore: store, autoRefresh: false)

        let blocked = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/drm.m4p"),
            fileName: "drm.m4p",
            fileExtension: "m4p",
            title: "DRM Song",
            artist: "A",
            album: nil,
            durationSeconds: 100,
            byteCount: 1000,
            codecHint: "drm",
            compatibility: TrackCompatibility(status: .blocked, messages: ["DRM protected"]),
            isSelected: false
        )
        let ready = readyTrack(name: "run.mp3", title: "Run", artist: "Artist")
        let already = readyTrack(name: "same.mp3", title: "Same", artist: "B", size: 3000, duplicate: true)
        // Force exact already-both via device file matching size+name
        model.tracks = [ready, blocked, already]
        model.deviceBrowser.files = [
            DeviceFile(
                objectID: "1",
                name: "same.mp3",
                type: .audio,
                size: 3000,
                path: "Music/same.mp3",
                backendKind: .mtp,
                audioMetadata: DeviceAudioMetadata(title: "Same", artist: "B")
            )
        ]

        let session = GuidedTransferSession()
        let plan = session.buildPlan(
            mode: .toWatch,
            model: model,
            macTracks: model.tracks,
            stats: GuidedCatalogStats(queueCount: 3, uniqueTracks: 3)
        )

        XCTAssertEqual(plan.toWatchItems.count, 1)
        XCTAssertEqual(plan.toWatchItems.first?.displayName, ready.displayName)
        XCTAssertTrue(plan.items.contains { $0.bucket == .cannotTransfer })
        XCTAssertTrue(plan.items.contains { $0.bucket == .alreadyBoth })
    }

    func testConflictResolutionAffectsToWatchAndFromWatch() {
        let defaults = UserDefaults(suiteName: "GuidedConflict.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let model = AppModel(settingsStore: store, autoRefresh: false)
        let mac = readyTrack(name: "song.mp3", title: "Song", artist: "X", size: 1000)
        model.tracks = [mac]
        model.deviceBrowser.files = [
            DeviceFile(
                objectID: "9",
                name: "song.mp3",
                type: .audio,
                size: 2000,
                path: "Music/song.mp3",
                backendKind: .mtp,
                audioMetadata: DeviceAudioMetadata(title: "Song", artist: "X")
            )
        ]

        let session = GuidedTransferSession()
        var plan = session.buildPlan(
            mode: .bothWays,
            model: model,
            macTracks: [mac],
            stats: GuidedCatalogStats(uniqueTracks: 1)
        )
        session.plan = plan
        XCTAssertFalse(plan.conflictItems.isEmpty)

        let conflictID = plan.conflictItems[0].id
        session.setConflictResolution(itemID: conflictID, resolution: .sendMacVersion)
        XCTAssertEqual(session.plan?.toWatchItems.count, 1)
        XCTAssertEqual(session.plan?.fromWatchItems.count, 0)

        session.setConflictResolution(itemID: conflictID, resolution: .importWatchVersion)
        XCTAssertEqual(session.plan?.toWatchItems.count, 0)
        XCTAssertEqual(session.plan?.fromWatchItems.count, 1)

        session.setConflictResolution(itemID: conflictID, resolution: .keepBothCopies)
        XCTAssertEqual(session.plan?.toWatchItems.count, 1)
        XCTAssertEqual(session.plan?.fromWatchItems.count, 1)

        session.setConflictResolution(itemID: conflictID, resolution: .skipBoth)
        XCTAssertEqual(session.plan?.toWatchItems.count, 0)
        XCTAssertEqual(session.plan?.fromWatchItems.count, 0)
    }

    func testWizardStepOrdering() {
        XCTAssertTrue(GuidedWizardStep.pairWatch < GuidedWizardStep.chooseMode)
        XCTAssertTrue(GuidedWizardStep.confirmPlan < GuidedWizardStep.transferProgress)
        XCTAssertEqual(GuidedWizardStep.progressSteps.count, 7)
    }

    func testTransferModesHaveCopy() {
        XCTAssertTrue(GuidedTransferMode.toWatch.subtitle.lowercased().contains("scan"))
        XCTAssertTrue(GuidedTransferMode.bothWays.subtitle.lowercased().contains("conflict"))
    }
}
