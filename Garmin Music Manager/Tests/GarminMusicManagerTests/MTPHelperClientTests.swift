import XCTest
@testable import GarminMusicManager
import GarminMusicCore

private struct FakeTransport: MTPHelperTransport {
    var result: Result<Data, Error>
    var onSend: (@Sendable (Data, TimeInterval) -> Void)?

    func send(_ requestData: Data, timeout: TimeInterval) async throws -> Data {
        onSend?(requestData, timeout)
        return try result.get()
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
        let result = DeviceFileOperationResult(completedCount: 3, failedItems: ["bad.mp3"], message: "3 file(s) uploaded; 1 failed.")
        let data = try encoded(MTPHelperResponse(ok: true, operationResult: result))
        let client = MTPHelperClient(transport: FakeTransport(result: .success(data)))

        let decoded = try await client.operationResult(request: MTPHelperRequest(operation: .upload))
        XCTAssertEqual(decoded, result)
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
}
