// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GarminMusicManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "GarminMusicManager",
            targets: ["GarminMusicManager"]
        )
    ],
    targets: [
        .executableTarget(
            name: "GarminMusicManager"
        )
    ]
)
