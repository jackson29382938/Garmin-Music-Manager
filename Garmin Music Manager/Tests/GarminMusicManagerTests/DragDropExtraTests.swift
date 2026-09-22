import Foundation
import XCTest
@testable import GarminMusicManager

@MainActor
final class FolderHoverOpenControllerTests: XCTestCase {
    func testCancelClearsPending() async {
        let controller = FolderHoverOpenController()
        controller.delay = 0.2
        var opened = false
        controller.pointerEntered(folderID: "a") {
            opened = true
        }
        XCTAssertEqual(controller.pendingFolderID, "a")
        controller.pointerExited(folderID: "a")
        XCTAssertNil(controller.pendingFolderID)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(opened)
    }

    func testDoesNotReopenSameFolderImmediately() async {
        let controller = FolderHoverOpenController()
        controller.delay = 0.05
        var openCount = 0
        controller.pointerEntered(folderID: "folder") {
            openCount += 1
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(openCount, 1)
        controller.pointerEntered(folderID: "folder") {
            openCount += 1
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(openCount, 1)
    }
}

final class FileNameCollisionTests: XCTestCase {
    func testKeepBothPreservesExtension() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepBoth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = folder.appendingPathComponent("Song.mp3")
        try Data("a".utf8).write(to: original)
        let next = FileNameCollision.keepBothURL(for: "Song.mp3", in: folder)
        XCTAssertEqual(next.lastPathComponent, "Song 2.mp3")
        try Data("b".utf8).write(to: next)
        let third = FileNameCollision.keepBothURL(for: "Song.mp3", in: folder)
        XCTAssertEqual(third.lastPathComponent, "Song 3.mp3")
    }
}
