import XCTest
@testable import GarminMusicManager
import GarminMusicCore

private struct FakeTransport: MTPHelperTransport {
    var result: Result<Data, Error>
    var onSend: (@Sendable (Data, TimeInterval) -> Void)?
    var progressEvents: [MTPProgressEvent] = []

    func send(
        _ requestData: Data,
        timeout: TimeInterval,
        onProgress: (@Sendable (MTPProgressEvent) -> Void)?
    ) async throws -> Data {
        onSend?(requestData, timeout)
        for event in progressEvents {
            onProgress?(event)
        }
        return try result.get()
    }
}

/// Returns a sequence of responses (one per `send` call). Used for multi-chunk / retry tests.
private final class SequencedFakeTransport: MTPHelperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private(set) var sendCount = 0

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    func send(
        _ requestData: Data,
        timeout: TimeInterval,
        onProgress: (@Sendable (MTPProgressEvent) -> Void)?
    ) async throws -> Data {
        _ = requestData
        _ = timeout
        _ = onProgress
        lock.lock()
        defer { lock.unlock() }
        sendCount += 1
        guard !results.isEmpty else {
            throw DeviceFileSystemError.helperFailed("No more sequenced results.")
        }
        return try results.removeFirst().get()
    }
}

final class MTPHelperClientTests: XCTestCase {
    private func encoded(_ response: MTPHelperResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(response)
    }

    func testSnapshotDecodesFromTransportData() async throws {
        let snapshot = DeviceFileSystemSnapshot(
            files: [
                DeviceFile(objectID: "42", name: "song.mp3", type: .audio, size: 1_234, path: "Music/song.mp3", backendKind: .mtp)
            ],
            collections: [],
            storageInfo: DeviceStorageInfo(totalCapacity: 1_000, availableCapacity: 500, usedByFiles: 100, fileCount: 1),
            deviceName: "Forerunner",
            diagnosticMessage: nil
        )
        let data = try encoded(MTPHelperResponse(ok: true, snapshot: snapshot))
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data)))

        let decoded = try await client.snapshot(request: MTPHelperRequest(operation: .listMusic))
        XCTAssertEqual(decoded, snapshot)
    }

    func testOperationResultDecodesFromTransportData() async throws {
        let result = DeviceFileOperationResult(
            completedCount: 3,
            failedItems: ["bad.mp3"],
            message: "3 file(s) uploaded; 1 failed.",
            uploadedFiles: [
                DeviceUploadedObject(displayName: "good.mp3", remotePath: "Music/good.mp3", size: 123, objectID: "42")
            ]
        )
        let data = try encoded(MTPHelperResponse(ok: true, operationResult: result))
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data)))

        let decoded = try await client.operationResult(request: MTPHelperRequest(operation: .upload))
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.uploadedFiles.first?.objectID, "42")
    }

    func testOperationResultDecodesLegacyPayloadWithoutUploadedFiles() throws {
        let json = """
        {"completedCount":1,"failedItems":[],"message":"1 file(s) uploaded."}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DeviceFileOperationResult.self, from: json)
        XCTAssertEqual(decoded.completedCount, 1)
        XCTAssertTrue(decoded.uploadedFiles.isEmpty)
    }

    func testHelperErrorResponseThrowsMatchingError() async throws {
        let error = MTPHelperError(code: "device-busy", message: "The Garmin is busy.")
        let data = try encoded(MTPHelperResponse(ok: false, error: error))
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data)))

        do {
            _ = try await client.snapshot(request: MTPHelperRequest(operation: .listMusic))
            XCTFail("Expected an error")
        } catch let thrown as MTPHelperError {
            XCTAssertEqual(thrown.code, "device-busy")
        }
    }

    func testGarbageResponseThrowsDiagnosticError() async throws {
        let data = Data("dyld: Library not loaded".utf8)
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data)))

        do {
            _ = try await client.snapshot(request: MTPHelperRequest(operation: .listMusic))
            XCTFail("Expected an error")
        } catch let thrown as DeviceFileSystemError {
            guard case .helperFailed(let message) = thrown else {
                return XCTFail("Unexpected error case: \(thrown)")
            }
            XCTAssertTrue(message.contains("dyld: Library not loaded"), "diagnostic should include raw output, got: \(message)")
        }
    }

    func testMissingSnapshotThrows() async throws {
        let data = try encoded(MTPHelperResponse(ok: true))
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data)))

        do {
            _ = try await client.snapshot(request: MTPHelperRequest(operation: .listMusic))
            XCTFail("Expected an error")
        } catch let thrown as DeviceFileSystemError {
            guard case .helperFailed = thrown else {
                return XCTFail("Unexpected error case: \(thrown)")
            }
        }
    }

    // MARK: Timeout scaling

    func testUploadTimeoutScalesWithItemCountAndBytes() {
        let client = MTPHelperClient(transport: FakeTransport(result: .success(Data())))

        let empty = MTPHelperRequest(operation: .upload)
        XCTAssertEqual(client.operationTimeout(for: empty), 60)

        // scaledTimeout is the pure function behind the per-request estimate.
        XCTAssertEqual(
            MTPHelperClient.scaledTimeout(base: 60, itemCount: 10, bytes: 100 * 1_048_576, secondsPerItem: 12, secondsPerMiB: 2.0, maximum: 3_600),
            60 + 120 + 200
        )
        XCTAssertEqual(
            MTPHelperClient.scaledTimeout(base: 60, itemCount: 10_000, bytes: 0, secondsPerItem: 12, secondsPerMiB: 2.0, maximum: 3_600),
            3_600,
            "estimate must cap at the maximum"
        )
        XCTAssertEqual(
            MTPHelperClient.scaledTimeout(base: 60, itemCount: 0, bytes: -5, secondsPerItem: 12, secondsPerMiB: 2.0, maximum: 3_600),
            60,
            "estimate must never fall below the base"
        )
    }

    func testDeleteTimeoutBounds() {
        let client = MTPHelperClient(transport: FakeTransport(result: .success(Data())))
        let few = MTPHelperRequest(operation: .delete, files: [])
        XCTAssertEqual(client.operationTimeout(for: few), 45, "delete timeout has a 45s floor")

        let many = MTPHelperRequest(operation: .delete, files: Array(
            repeating: DeviceFile(objectID: "1", name: "a", type: .audio, size: 0, path: "a", backendKind: .mtp),
            count: 500
        ))
        XCTAssertEqual(client.operationTimeout(for: many), 600, "delete timeout caps at 10 minutes")
    }

    func testProgressEventsAreForwardedBeforeResult() async throws {
        let progress = MTPProgressEvent(
            phase: "upload",
            itemIndex: 0,
            itemCount: 1,
            itemName: "song.mp3",
            bytesTransferred: 500,
            bytesTotal: 1_000,
            overallFraction: 0.5,
            message: "Uploading 1/1: song.mp3"
        )
        let result = DeviceFileOperationResult(completedCount: 1, failedItems: [], message: "1 file(s) uploaded.")
        let data = try encoded(MTPHelperResponse(ok: true, operationResult: result))
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data), progressEvents: [progress]))

        let box = ProgressBox()
        let decoded = try await client.operationResult(
            request: MTPHelperRequest(operation: .upload),
            onProgress: { event in box.append(event) }
        )
        XCTAssertEqual(decoded.completedCount, 1)
        XCTAssertEqual(box.events, [progress])
    }

    func testStreamLineProgressDecodes() throws {
        let event = MTPProgressEvent(
            phase: "upload",
            itemIndex: 2,
            itemCount: 5,
            itemName: "track.m4a",
            bytesTransferred: 100,
            bytesTotal: 400,
            overallFraction: 0.45,
            message: "Uploading 3/5: track.m4a"
        )
        let data = try MTPProgressLineEncoder.encode(event)
        let decoder = JSONDecoder()
        let line = try decoder.decode(MTPHelperStreamLine.self, from: data)
        XCTAssertTrue(line.isProgressOnly)
        XCTAssertEqual(line.progress, event)
        XCTAssertNil(line.asResponse)
    }

    func testCancelledHelperErrorMapsToCancellationError() async {
        let error = MTPHelperError(code: "cancelled", message: "Transfer cancelled.")
        let data = try! encoded(MTPHelperResponse(ok: false, error: error))
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data)))

        do {
            _ = try await client.operationResult(request: MTPHelperRequest(operation: .upload))
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCancelledWithPartialSuccessReturnsOperationResult() async throws {
        let partial = DeviceFileOperationResult(
            completedCount: 2,
            failedItems: ["c.mp3"],
            message: "Cancelled after 2 file(s) uploaded; 1 failed.",
            uploadedFiles: [
                DeviceUploadedObject(displayName: "a.mp3", remotePath: "Music/a.mp3", size: 1, objectID: "1"),
                DeviceUploadedObject(displayName: "b.mp3", remotePath: "Music/b.mp3", size: 1, objectID: "2")
            ]
        )
        let data = try encoded(MTPHelperResponse(
            ok: false,
            operationResult: partial,
            error: MTPHelperError(code: "cancelled", message: "Transfer cancelled.")
        ))
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data)))

        let result = try await client.operationResult(request: MTPHelperRequest(operation: .upload))
        XCTAssertEqual(result.completedCount, 2)
        XCTAssertEqual(result.uploadedFiles.count, 2)
        XCTAssertEqual(result.failedItems, ["c.mp3"])
    }

    func testUploadInChunksAggregatesResults() async throws {
        // Force small chunks by configuring the shared setting, then create a client
        // that uses a sequenced transport with two per-chunk responses.
        MTPHelperClient.configure(uploadChunkSize: 2, idleTimeout: 90)

        let chunk1 = DeviceFileOperationResult(
            completedCount: 2,
            failedItems: [],
            message: "2 file(s) uploaded.",
            uploadedFiles: [
                DeviceUploadedObject(displayName: "a.mp3", remotePath: "Music/a.mp3", size: 1, objectID: "1"),
                DeviceUploadedObject(displayName: "b.mp3", remotePath: "Music/b.mp3", size: 1, objectID: "2")
            ]
        )
        let chunk2 = DeviceFileOperationResult(
            completedCount: 1,
            failedItems: ["d.mp3"],
            message: "1 file(s) uploaded; 1 failed.",
            uploadedFiles: [
                DeviceUploadedObject(displayName: "c.mp3", remotePath: "Music/c.mp3", size: 1, objectID: "3")
            ]
        )
        let transport = SequencedFakeTransport(results: [
            .success(try encoded(MTPHelperResponse(ok: true, operationResult: chunk1))),
            .success(try encoded(MTPHelperResponse(ok: true, operationResult: chunk2)))
        ])
        let client = MTPHelperClient(transport: transport)
        // Instance may still use configured chunk size from configure().
        XCTAssertEqual(client.uploadChunkSize, 2)

        let files = ["a", "b", "c", "d"].map {
            DeviceUploadFile(localPath: "/tmp/\($0).mp3", remotePath: "Music/\($0).mp3", displayName: "\($0).mp3")
        }
        let result = try await client.operationResult(
            request: MTPHelperRequest(operation: .upload, uploadFiles: files)
        )

        XCTAssertEqual(transport.sendCount, 2)
        XCTAssertEqual(result.completedCount, 3)
        XCTAssertEqual(result.failedItems, ["d.mp3"])
        XCTAssertEqual(result.uploadedFiles.count, 3)

        // Restore defaults for other tests.
        MTPHelperClient.configure(uploadChunkSize: 5, idleTimeout: 90)
    }

    func testTransientErrorRetriesThenSucceeds() async throws {
        let success = DeviceFileOperationResult(completedCount: 1, failedItems: [], message: "1 file(s) uploaded.")
        let transport = SequencedFakeTransport(results: [
            .success(try encoded(MTPHelperResponse(
                ok: false,
                error: MTPHelperError(code: "device-busy", message: "The Garmin is busy.")
            ))),
            .success(try encoded(MTPHelperResponse(ok: true, operationResult: success)))
        ])
        let client = MTPHelperClient(transport: transport)

        let result = try await client.operationResult(
            request: MTPHelperRequest(
                operation: .upload,
                uploadFiles: [DeviceUploadFile(localPath: "/tmp/a.mp3", remotePath: "Music/a.mp3", displayName: "a.mp3")]
            )
        )
        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(transport.sendCount, 2)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [MTPProgressEvent] = []

    func append(_ event: MTPProgressEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
