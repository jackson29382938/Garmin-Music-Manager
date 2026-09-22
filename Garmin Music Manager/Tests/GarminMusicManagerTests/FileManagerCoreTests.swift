import XCTest
@testable import GarminMusicManager
import GarminMusicCore

final class LocalFileOperationsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmm-local-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateRenameDuplicateAndTrash() throws {
        let folder = try LocalFileOperations.createFolder(named: "Album", in: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        let file = folder.appendingPathComponent("track.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let (renamed, undoRename) = try LocalFileOperations.rename(file, to: "song.txt")
        XCTAssertEqual(renamed.lastPathComponent, "song.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try LocalFileOperations.undo(undoRename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let (_, _) = try LocalFileOperations.rename(file, to: "song.txt")
        let renamedAgain = folder.appendingPathComponent("song.txt")
        let dup = try LocalFileOperations.duplicate([renamedAgain])
        XCTAssertEqual(dup.completed, 1)

        let trash = try LocalFileOperations.trash([renamedAgain])
        XCTAssertEqual(trash.completed, 1)
        XCTAssertNotNil(trash.undo)
        if let undo = trash.undo {
            try LocalFileOperations.undo(undo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: renamedAgain.path))
        }
    }

    func testCompressAndDecompress() throws {
        let file = tempDir.appendingPathComponent("a.txt")
        try "payload".write(to: file, atomically: true, encoding: .utf8)
        let zip = try LocalFileOperations.compress([file], into: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))

        let out = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try LocalFileOperations.decompress(zip, into: out)
        let extracted = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        XCTAssertFalse(extracted.isEmpty)
    }
}

final class FileClipboardTests: XCTestCase {
    @MainActor
    func testCopyCutAndConsume() {
        let clip = FileClipboard()
        let url = URL(fileURLWithPath: "/tmp/a.mp3")
        clip.copyLocal([url], names: ["a.mp3"], from: .mac)
        XCTAssertEqual(clip.mode, .copy)
        XCTAssertFalse(clip.isEmpty)

        clip.cutDevice(ids: ["1"], names: ["x"], from: .garmin)
        XCTAssertEqual(clip.mode, .cut)
        XCTAssertEqual(clip.deviceFileIDs, ["1"])
        clip.consumeIfCut()
        XCTAssertTrue(clip.isEmpty)
    }
}

final class DualPaneSyncPlannerTests: XCTestCase {
    func testCopyAndMirrorPlans() {
        let left = [
            SyncListingItem(name: "a.mp3", size: 10, modified: Date(timeIntervalSince1970: 100), isDirectory: false, localURL: nil, deviceFileID: "a"),
            SyncListingItem(name: "b.mp3", size: 20, modified: Date(timeIntervalSince1970: 200), isDirectory: false, localURL: nil, deviceFileID: "b"),
        ]
        let right = [
            SyncListingItem(name: "a.mp3", size: 10, modified: Date(timeIntervalSince1970: 50), isDirectory: false, localURL: URL(fileURLWithPath: "/tmp/a.mp3"), deviceFileID: nil),
            SyncListingItem(name: "c.mp3", size: 5, modified: nil, isDirectory: false, localURL: URL(fileURLWithPath: "/tmp/c.mp3"), deviceFileID: nil),
        ]

        let copy = DualPaneSyncPlanner.plan(action: .copyLeftToRight, left: left, right: right)
        XCTAssertEqual(copy.copyCount, 1)
        XCTAssertEqual(copy.items.first?.name, "b.mp3")

        let mirror = DualPaneSyncPlanner.plan(action: .mirrorLeftToRight, left: left, right: right)
        XCTAssertEqual(mirror.copyCount, 1)
        XCTAssertEqual(mirror.deleteCount, 1)
        XCTAssertTrue(mirror.action.isDestructive)
    }

    func testSyncNewerUsesDates() {
        let left = [
            SyncListingItem(name: "a.mp3", size: 10, modified: Date(timeIntervalSince1970: 200), isDirectory: false, localURL: nil, deviceFileID: "a"),
        ]
        let right = [
            SyncListingItem(name: "a.mp3", size: 10, modified: Date(timeIntervalSince1970: 100), isDirectory: false, localURL: URL(fileURLWithPath: "/tmp/a.mp3"), deviceFileID: nil),
        ]
        let plan = DualPaneSyncPlanner.plan(action: .syncNewerLeftToRight, left: left, right: right)
        XCTAssertEqual(plan.copyCount, 1)
    }
}

final class MTPEmulationLayerTests: XCTestCase {
    func testNoticesExistForAllKinds() {
        for kind in [MTPEmulationKind.createFolder, .rename, .move, .zipRoundTrip] {
            let notice = MTPEmulationLayer.notice(for: kind)
            XCTAssertFalse(notice.title.isEmpty)
            XCTAssertFalse(notice.message.isEmpty)
        }
    }
}

final class DeviceFolderRenameStoreTests: XCTestCase {
    @MainActor
    func testCreateFolderAndRenameViaFake() async {
        let fake = FakeDeviceFileSystem()
        let store = DeviceBrowserStore()
        store.configure(backend: fake)
        let created = await store.createFolder(named: "Runs", parentPath: "Music")
        XCTAssertEqual(created?.completedCount, 1)
        XCTAssertEqual(fake.createFolderCallCount, 1)
        XCTAssertEqual(fake.lastCreatedFolderName, "Runs")

        let file = DeviceFile(
            objectID: "1",
            name: "old.mp3",
            type: .audio,
            size: 100,
            path: "Music/old.mp3",
            backendKind: .mtp
        )
        store.selectedFileIDs = [file.id]
        // Inject file into store by applying a snapshot through fake + refresh
        fake.listMusicSnapshot = DeviceFileSystemSnapshot(
            files: [file],
            collections: [],
            storageInfo: DeviceStorageInfo(totalCapacity: 1, availableCapacity: 1, usedByFiles: 0, fileCount: 1),
            deviceName: "Fake",
            diagnosticMessage: nil
        )
        await store.refresh(force: true)
        store.selectedFileIDs = [file.id]
        let renamed = await store.renameSelected(to: "new.mp3")
        XCTAssertEqual(renamed?.completedCount, 1)
        XCTAssertEqual(fake.renameCallCount, 1)
        XCTAssertEqual(fake.lastRenameNewName, "new.mp3")
    }
}

final class FileManagerSettingsRoundTripTests: XCTestCase {
    func testNewFileManagerSettingsRoundTrip() throws {
        var settings = LibrarySettings.default
        settings.fileManagerFavoritePaths = ["/Users/me/Music"]
        settings.fileManagerMacTabPaths = ["/Users/me/Music", "/Users/me/Desktop"]
        settings.fileManagerShowHiddenFiles = true
        settings.fileManagerViewMode = LocalViewMode.icons.rawValue
        settings.fileManagerRecursiveSearch = true
        settings.notifyOnMTPEmulation = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(LibrarySettings.self, from: data)
        XCTAssertEqual(decoded.fileManagerFavoritePaths, ["/Users/me/Music"])
        XCTAssertEqual(decoded.fileManagerMacTabPaths.count, 2)
        XCTAssertTrue(decoded.fileManagerShowHiddenFiles)
        XCTAssertEqual(decoded.fileManagerViewMode, LocalViewMode.icons.rawValue)
        XCTAssertTrue(decoded.fileManagerRecursiveSearch)
        XCTAssertFalse(decoded.notifyOnMTPEmulation)
    }
}
