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
        .target(
            name: "GarminMusicCore"
        ),
        .executableTarget(
            name: "GarminMTPHelper",
            dependencies: ["GarminMusicCore"]
        ),
        .executableTarget(
            name: "GarminMusicManager",
            dependencies: ["GarminMusicCore"],
            linkerSettings: [
                .linkedFramework("iTunesLibrary")
            ]
        ),
        .testTarget(
            name: "GarminMusicManagerTests",
            dependencies: [
                "GarminMusicCore"
            ]
        )
    ]
)
