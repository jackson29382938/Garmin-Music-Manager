import Foundation
import GarminMusicCore

// Cross-platform console front-end for the portable GarminMusicCore engine.
// Builds and runs on Windows, Linux, and macOS. The full SwiftUI app is macOS
// only; this CLI exposes the platform-independent playlist / path / compatibility
// logic so it can be built and exercised on a Windows PC.

let arguments = Array(CommandLine.arguments.dropFirst())

func platformName() -> String {
    #if os(Windows)
    return "Windows"
    #elseif os(macOS)
    return "macOS"
    #elseif os(Linux)
    return "Linux"
    #else
    return "Unknown"
    #endif
}

func printBanner() {
    print("Garmin Music Manager — core CLI (\(platformName()))")
    print(String(repeating: "=", count: 44))
}

func printUsage() {
    print("""
    Usage:
      GarminMusicCLI selftest            Run built-in checks against the core engine
      GarminMusicCLI playlist <file>     Parse an .m3u/.m3u8 file and print normalized track paths
      GarminMusicCLI check <path...>     Report Garmin compatibility for one or more audio file paths
      GarminMusicCLI help                Show this help
    """)
}

/// Exercises the portable engine end-to-end and returns the number of failures.
func runSelfTest() -> Int {
    var failures = 0
    func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        print("[\(condition ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        if !condition { failures += 1 }
    }

    let playlist = """
    #EXTM3U
    #EXTINF:212,Artist A - Song One
    0:/MUSIC/ArtistA/Song One.mp3
    \\Music\\ArtistB\\Song Two.mp3
    File3=0:/MUSIC/ArtistC/Song Three.mp3
    https://example.com/stream.mp3
    """
    let paths = M3UPlaylistParser.parseTrackPaths(from: playlist)
    check("M3U parser skips comments + remote URLs", paths.count == 3, "got \(paths.count)")

    let normalized = M3UPlaylistParser.normalizePath("0:/MUSIC/ArtistA/Song One.mp3")
    check("Path normalization", normalized == "music/artista/song one.mp3", normalized)

    let files = [
        DeviceFile(objectID: "f1", name: "Song One.mp3", type: .audio, size: 5_000_000,
                   path: "0:/MUSIC/ArtistA/Song One.mp3", backendKind: .mtp),
        DeviceFile(objectID: "f2", name: "Song Two.mp3", type: .audio, size: 4_200_000,
                   path: "0:/MUSIC/ArtistB/Song Two.mp3", backendKind: .mtp),
        DeviceFile(objectID: "f3", name: "Song Three.mp3", type: .audio, size: 6_100_000,
                   path: "0:/MUSIC/ArtistC/Song Three.mp3", backendKind: .mtp)
    ]
    let matched = M3UPlaylistParser.match(references: paths, files: files)
    check("Playlist matches all device files in order", matched.fileIDs == files.map(\.id))

    let friendly = MTPErrorTranslator.friendlyMessage(for: ["LIBUSB_ERROR_ACCESS claim_interface failed"])
    check("MTP error translation", friendly?.contains("Another app is using the Garmin") == true)

    let flac = MusicCompatibilityEvaluator.evaluate(
        url: URL(fileURLWithPath: "song.flac"), ext: "flac",
        codecHint: nil, title: "Song", artist: "Artist", byteCount: 10_000_000)
    let mp3 = MusicCompatibilityEvaluator.evaluate(
        url: URL(fileURLWithPath: "song.mp3"), ext: "mp3",
        codecHint: nil, title: "Song", artist: "Artist", byteCount: 10_000_000)
    check("FLAC blocked / MP3 ready", flac.status == .blocked && mp3.status == .ready)

    let rel = SyncPathResolver.targetRelativePath(
        playlistName: "Running Mix", fileName: "Song One.mp3",
        organization: .byArtist, artist: "Artist A", albumComponents: ["Album X"])
    check("Sync path resolver organizes by artist", rel == "Running Mix/Artist A/Song One.mp3", rel)

    let text = M3UWriter().playlistText(entries: [
        .init(relativePath: "ArtistA/Song One.mp3", displayName: "Song One", durationSeconds: 212)
    ])
    check("M3UWriter emits #EXTM3U", text.hasPrefix("#EXTM3U") && text.contains("#EXTINF:212,Song One"))

    print(String(repeating: "-", count: 44))
    print(failures == 0 ? "All core checks passed." : "\(failures) check(s) failed.")
    return failures
}

func runPlaylist(_ file: String) -> Int {
    let url = URL(fileURLWithPath: file)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write(Data("error: could not read \(file)\n".utf8))
        return 1
    }
    let paths = M3UPlaylistParser.parseTrackPaths(from: text)
    print("Parsed \(paths.count) track reference(s) from \(url.lastPathComponent):")
    for path in paths {
        print("  \(path)")
        print("    normalized: \(M3UPlaylistParser.normalizePath(path))")
    }
    return 0
}

func runCheck(_ paths: [String]) -> Int {
    guard !paths.isEmpty else {
        FileHandle.standardError.write(Data("error: provide at least one file path\n".utf8))
        return 1
    }
    for path in paths {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let result = MusicCompatibilityEvaluator.evaluate(
            url: url, ext: ext, codecHint: nil, title: nil, artist: nil, byteCount: size)
        print("\(url.lastPathComponent): \(result.status.rawValue)")
        for message in result.messages {
            print("  - \(message)")
        }
    }
    return 0
}

printBanner()

let command = arguments.first ?? "selftest"
let rest = Array(arguments.dropFirst())
let exitCode: Int

switch command {
case "selftest":
    exitCode = runSelfTest()
case "playlist":
    guard let file = rest.first else {
        FileHandle.standardError.write(Data("error: playlist requires a file path\n".utf8))
        printUsage()
        exit(1)
    }
    exitCode = runPlaylist(file)
case "check":
    exitCode = runCheck(rest)
case "help", "-h", "--help":
    printUsage()
    exitCode = 0
default:
    FileHandle.standardError.write(Data("error: unknown command '\(command)'\n".utf8))
    printUsage()
    exitCode = 1
}

exit(Int32(exitCode))
