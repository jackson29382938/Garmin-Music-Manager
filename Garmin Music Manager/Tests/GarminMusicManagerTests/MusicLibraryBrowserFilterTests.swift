import XCTest
@testable import GarminMusicManager

final class MusicLibraryBrowserFilterTests: XCTestCase {
    func testAvailabilityAndFormatFilters() {
        let local = LibraryTrack(
            id: "1",
            title: "Local",
            artist: "A",
            album: "B",
            location: URL(fileURLWithPath: "/tmp/a.mp3"),
            isCloudOnly: false,
            isDRMProtected: false,
            fileExtension: "mp3"
        )
        let cloud = LibraryTrack(
            id: "2",
            title: "Cloud",
            artist: nil,
            album: "B",
            location: nil,
            isCloudOnly: true,
            isDRMProtected: false,
            fileExtension: "m4a"
        )
        let drm = LibraryTrack(
            id: "3",
            title: "DRM",
            artist: "A",
            album: nil,
            location: URL(fileURLWithPath: "/tmp/c.m4a"),
            isCloudOnly: false,
            isDRMProtected: true,
            fileExtension: "m4a"
        )

        var filters = LibraryTrackBrowserFilters(availability: .importableOnly)
        XCTAssertTrue(filters.matches(local))
        XCTAssertFalse(filters.matches(cloud))
        XCTAssertFalse(filters.matches(drm))

        filters.availability = .cloudOnly
        XCTAssertTrue(filters.matches(cloud))

        filters.availability = .all
        filters.format = .mp3
        XCTAssertTrue(filters.matches(local))
        XCTAssertFalse(filters.matches(cloud))

        filters.format = .aac
        XCTAssertTrue(filters.matches(cloud))
        XCTAssertTrue(filters.matches(drm))

        filters.format = .all
        filters.metadata = .missingArtist
        XCTAssertTrue(filters.matches(cloud))
        XCTAssertFalse(filters.matches(local))
    }

    func testSortOrdersTitleAndImportableFirst() {
        let b = LibraryTrack(
            id: "b",
            title: "Bravo",
            artist: "Z",
            album: "A",
            location: nil,
            isCloudOnly: true,
            isDRMProtected: false,
            fileExtension: "m4a"
        )
        let a = LibraryTrack(
            id: "a",
            title: "Alpha",
            artist: "A",
            album: "Z",
            location: URL(fileURLWithPath: "/tmp/a.mp3"),
            isCloudOnly: false,
            isDRMProtected: false,
            fileExtension: "mp3"
        )

        XCTAssertEqual([b, a].sorted(by: .titleAscending).map(\.id), ["a", "b"])
        XCTAssertEqual([b, a].sorted(by: .titleDescending).map(\.id), ["b", "a"])
        XCTAssertEqual([b, a].sorted(by: .importableFirst).map(\.id), ["a", "b"])
        XCTAssertEqual([a, b].sorted(by: .artistAscending).map(\.id), ["a", "b"])
    }
}
