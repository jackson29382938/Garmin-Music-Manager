// swift-tools-version: 5.9

import PackageDescription

// The full SwiftUI application (`GarminMusicManager`) and the libmtp worker
// (`GarminMTPHelper`) depend on Apple-only frameworks (SwiftUI, AppKit,
// iTunesLibrary) and `Darwin`, so they only build on macOS. `GarminMusicCore`
// is pure Foundation and builds anywhere Swift runs — including Windows and
// Linux — so it (plus the `GarminMusicCLI` console front-end and the core test
// suite) are always available. The macOS-only pieces are gated behind
// `#if os(macOS)` so `swift build` / `swift test` succeed on Windows and Linux.

var products: [Product] = [
    .library(
        name: "GarminMusicCore",
        targets: ["GarminMusicCore"]
    ),
    .executable(
        name: "GarminMusicCLI",
        targets: ["GarminMusicCLI"]
    )
]

var targets: [Target] = [
    .target(
        name: "GarminMusicCore"
    ),
    .executableTarget(
        name: "GarminMusicCLI",
        dependencies: ["GarminMusicCore"]
    ),
    .testTarget(
        name: "GarminMusicCoreTests",
        dependencies: ["GarminMusicCore"]
    )
]

#if os(macOS)
products += [
    .executable(
        name: "GarminMusicManager",
        targets: ["GarminMusicManager"]
    ),
    .executable(
        name: "GarminMTPHelper",
        targets: ["GarminMTPHelper"]
    )
]

targets += [
    .systemLibrary(
        name: "CLibMTP",
        path: "Sources/CLibMTP",
        pkgConfig: "libmtp",
        providers: [
            .brew(["libmtp"])
        ]
    ),
    .executableTarget(
        name: "GarminMTPHelper",
        dependencies: [
            "GarminMusicCore",
            "CLibMTP"
        ],
        linkerSettings: [
            .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]),
            .linkedLibrary("mtp")
        ]
    ),
    .executableTarget(
        name: "GarminMusicManager",
        dependencies: ["GarminMusicCore"],
        path: "Sources/GarminMusicManager",
        resources: [
            .process("Resources")
        ],
        linkerSettings: [
            .linkedFramework("iTunesLibrary")
        ]
    ),
    .testTarget(
        name: "GarminMusicManagerTests",
        dependencies: [
            "GarminMusicCore",
            "GarminMusicManager"
        ]
    )
]
#endif

let package = Package(
    name: "GarminMusicManager",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
