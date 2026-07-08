// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GarminMusicManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GarminMusicCore",
            targets: ["GarminMusicCore"]
        ),
        .executable(
            name: "GarminMusicManager",
            targets: ["GarminMusicManager"]
        ),
        .executable(
            name: "GarminMTPHelper",
            targets: ["GarminMTPHelper"]
        )
    ],
    targets: [
        .systemLibrary(
            name: "CLibMTP",
            path: "Sources/CLibMTP",
            pkgConfig: "libmtp",
            providers: [
                .brew(["libmtp"])
            ]
        ),
        .target(
            name: "GarminMusicCore"
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
)
