import XCTest
import GarminMusicCore
@testable import GarminMusicManager

@MainActor
final class DeviceBrowserStoreTests: XCTestCase {
    func testRefreshAppliesSnapshot() async {
        let file = DeviceFile(
            objectID: "1",
            name: "a.mp3",
            type: .audio,
            size: 100,
            path: "Music/a.mp3",
            backendKind: .mtp
        )
        let snapshot = DeviceFileSystemSnapshot(
            files: [file],
            collections: [DeviceCollection(id: "all-music", name: "All Music", kind: .allMusic, fileIDs: [file.id])],
            storageInfo: DeviceStorageInfo(totalCapacity: 1000, availableCapacity: 400, usedByFiles: 100, fileCount: 1),
            deviceName: "Forerunner",
            diagnosticMessage: nil
        )
        let fake = FakeDeviceFileSystem(listMusicSnapshot: snapshot)
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        await store.refresh(force: true)

        XCTAssertEqual(store.files.count, 1)
        XCTAssertEqual(store.files.first?.name, "a.mp3")
        XCTAssertEqual(store.storageInfo?.availableCapacity, 400)
        XCTAssertEqual(store.deviceName, "Forerunner")
        XCTAssertNil(store.operation)
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.hasFreshListing)
    }

    func testUploadPartialSuccessKeepsResultAndOperationState() async {
        let fake = FakeDeviceFileSystem()
        fake.uploadResults = [
            .success(DeviceFileOperationResult(
                completedCount: 2,
                failedItems: ["c.mp3"],
                message: "2 file(s) uploaded; 1 failed.",
                uploadedFiles: [
                    DeviceUploadedObject(displayName: "a.mp3", remotePath: "Music/a.mp3", size: 10, objectID: "1"),
                    DeviceUploadedObject(displayName: "b.mp3", remotePath: "Music/b.mp3", size: 10, objectID: "2")
                ]
            ))
        ]
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        let result = await store.upload(
            [
                DeviceUploadFile(localPath: "/tmp/a.mp3", remotePath: "Music/a.mp3", displayName: "a.mp3"),
                DeviceUploadFile(localPath: "/tmp/b.mp3", remotePath: "Music/b.mp3", displayName: "b.mp3"),
                DeviceUploadFile(localPath: "/tmp/c.mp3", remotePath: "Music/c.mp3", displayName: "c.mp3")
            ],
            refreshAfter: false
        )

        XCTAssertEqual(result?.completedCount, 2)
        XCTAssertEqual(result?.failedItems, ["c.mp3"])
        XCTAssertEqual(store.operation?.phase, "Partial success")
        XCTAssertNotNil(store.lastError)
    }

    func testUploadCancelReturnsNilWithoutFailingRemaining() async {
        let fake = FakeDeviceFileSystem()
        fake.uploadResults = [.failure(CancellationError())]
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        let result = await store.upload(
            [DeviceUploadFile(localPath: "/tmp/a.mp3", remotePath: "Music/a.mp3", displayName: "a.mp3")],
            refreshAfter: false
        )

        XCTAssertNil(result)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.statusMessage, "Cancelled.")
        XCTAssertNil(store.operation)
    }

    func testUploadProgressUpdatesOperation() async {
        let fake = FakeDeviceFileSystem()
        fake.progressEventsPerUpload = [
            MTPProgressEvent(
                phase: "upload",
                itemIndex: 0,
                itemCount: 1,
                itemName: "a.mp3",
                bytesTransferred: 50,
                bytesTotal: 100,
                overallFraction: 0.5,
                message: "Uploading 1/1: a.mp3"
            )
        ]
        fake.uploadResults = [
            .success(DeviceFileOperationResult(completedCount: 1, failedItems: [], message: "1 file(s) uploaded."))
        ]
        let store = DeviceBrowserStore()
        store.configure(backend: fake)

        let box = ProgressCollector()
        _ = await store.upload(
            [DeviceUploadFile(localPath: "/tmp/a.mp3", remotePath: "Music/a.mp3", displayName: "a.mp3")],
            refreshAfter: false,
            onProgress: { event in box.append(event) }
        )

        XCTAssertEqual(box.events.count, 1)
        XCTAssertEqual(box.events.first?.overallFraction, 0.5)
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [MTPProgressEvent] = []

    func append(_ event: MTPProgressEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
