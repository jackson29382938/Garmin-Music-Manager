import Foundation
import XCTest
@testable import GarminMusicManager

@MainActor
final class LocalFolderBrowserStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFolderBrowserStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let music = tempRoot.appendingPathComponent("Music", isDirectory: true)
        let nested = music.appendingPathComponent("Albums", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try Data("audio".utf8).write(to: music.appendingPathComponent("song.mp3"))
        try Data("list".utf8).write(to: music.appendingPathComponent("list.m3u8"))
        try Data("note".utf8).write(to: music.appendingPathComponent("readme.txt"))
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    func testListsFoldersAndAudioWithSearchFilter() {
        let music = tempRoot.appendingPathComponent("Music", isDirectory: true)
        let store = LocalFolderBrowserStore(folder: music)

        XCTAssertEqual(store.currentFolder.standardizedFileURL, music.standardizedFileURL)
        XCTAssertTrue(store.entries.contains { $0.name == "Albums" && $0.kind == .folder })
        XCTAssertTrue(store.entries.contains { $0.name == "song.mp3" && $0.kind == .audio })
        XCTAssertTrue(store.entries.contains { $0.name == "list.m3u8" && $0.kind == .playlist })
        XCTAssertTrue(store.entries.contains { $0.name == "readme.txt" && $0.kind == .other })

        store.searchText = "song"
        XCTAssertEqual(store.displayedEntries.map(\.name), ["song.mp3"])
    }

    func testNavigateUpAndDefaultMusicFallback() {
        let music = tempRoot.appendingPathComponent("Music", isDirectory: true)
        let nested = music.appendingPathComponent("Albums", isDirectory: true)
        let store = LocalFolderBrowserStore(folder: nested)

        XCTAssertTrue(store.canNavigateUp)
        store.navigateUp()
        XCTAssertEqual(store.currentFolder.standardizedFileURL, music.standardizedFileURL)

        let missing = tempRoot.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let fallback = LocalFolderBrowserStore(folder: missing)
        XCTAssertEqual(
            fallback.currentFolder.standardizedFileURL,
            LocalFolderBrowserStore.defaultMusicFolder.standardizedFileURL
        )
    }

    func testSelectionHelpers() {
        let music = tempRoot.appendingPathComponent("Music", isDirectory: true)
        let store = LocalFolderBrowserStore(folder: music)
        store.selectAllDisplayed()
        XCTAssertEqual(store.selectedIDs.count, store.displayedEntries.count)
        XCTAssertFalse(store.selectedAudioURLs.isEmpty)
        store.deselectAll()
        XCTAssertTrue(store.selectedIDs.isEmpty)
    }
}

final class FileManagerLibrarySettingsTests: XCTestCase {
    func testFileManagerFieldsRoundTripAndLegacyDecode() throws {
        var lib = LibrarySettings.default
        lib.fileManagerMacMode = FileManagerMacMode.appleMusic.rawValue
        lib.fileManagerLastFolderPath = "/Users/test/Music"
        let data = try JSONEncoder().encode(lib)
        let decoded = try JSONDecoder().decode(LibrarySettings.self, from: data)
        XCTAssertEqual(decoded.fileManagerMacMode, FileManagerMacMode.appleMusic.rawValue)
        XCTAssertEqual(decoded.fileManagerLastFolderPath, "/Users/test/Music")

        // Legacy blob without File Manager keys still decodes with defaults.
        var object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(LibrarySettings.default)) as! [String: Any]
        object.removeValue(forKey: "fileManagerMacMode")
        object.removeValue(forKey: "fileManagerLastFolderPath")
        let migrated = try JSONDecoder().decode(
            LibrarySettings.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(migrated.fileManagerMacMode, FileManagerMacMode.folders.rawValue)
        XCTAssertNil(migrated.fileManagerLastFolderPath)
    }

    func testAppModeIncludesFileManager() {
        XCTAssertEqual(AppMode.fileManager.shortTitle, "File Manager")
        XCTAssertEqual(AppMode.fileManager.systemImage, "folder")
        XCTAssertNotNil(AppMode(rawValue: "fileManager"))
    }
}
