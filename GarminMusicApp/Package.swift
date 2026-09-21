// swift-tools-version: 5.10

import PackageDescription

// Cross-platform SwiftCrossUI front-end for Garmin Music Manager.
//
// Runs natively on Windows (WinUI), macOS (AppKit), and Linux (Gtk) from a
// single Swift codebase, reusing the portable `GarminMusicCore` engine from the
// sibling package. `DefaultBackend` selects the right native backend per OS.
let package = Package(
    name: "GarminMusicApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/stackotter/swift-cross-ui", .upToNextMinor(from: "0.2.0")),
        .package(path: "../Garmin Music Manager")
    ],
    targets: [
        .executableTarget(
            name: "GarminMusicApp",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "GarminMusicCore", package: "Garmin Music Manager")
            ]
        )
    ]
)
