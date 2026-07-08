# Garmin Music Manager

A native macOS SwiftUI app for managing local music files on Garmin music watches.

## Features

- **Device detection** — scans `/Volumes` for Garmin-like mounted devices (Fenix, Forerunner, Venu, Epix, etc.) and reports/syncs Garmin USB/MTP devices via libmtp
- **Fast MTP path** — long-lived helper reuses one USB/MTP session across browse + multi-file sync; uploads are chunked with retries
- **Portable MTP bootstrap** — automatically installs Homebrew/libmtp if MTP tools are missing on a new Mac
- **Manual destination** — choose any writable music folder (for MTP watches exposed by another tool)
- **Import music** — add files, add folders (recursive scan), or drag-and-drop
- **Apple Music integration** — browse your Music.app library by playlist or album (via the `iTunesLibrary` framework) and import local, non-DRM tracks directly
- **Compatibility checks** — warns about ALAC, DRM, missing metadata, unsupported formats, large files
- **Duplicate detection** — marks tracks already present on the destination
- **Sync preview** — dry-run before copying (copy / skip / replace / keep both)
- **Flexible sync** — overwrite policies, artist/album folders; M3U8 on mounted volumes and native MTP playlists
- **Playlist import** — load local tracks from `.m3u` / `.m3u8` files
- **Device contents** — browse existing audio on destination, delete with confirmation
- **Storage budgeting** — shows free/used space and warns when selected tracks exceed available storage
- **Persistence** — remembers last destination, playlist name, and sync settings
- **Optional audio conversion** — ALAC/FLAC → AAC when ffmpeg is installed (Settings)

## Important limitation

Many Garmin music watches connect to macOS using **MTP**. macOS does not expose all MTP devices as normal Finder volumes. This app supports:

1. Garmin devices/folders that appear under `/Volumes`
2. Direct MTP detection and transfer through `libmtp` (via the long-lived `GarminMTPHelper --serve` process)
3. Automatic first-run bootstrap of Homebrew + `libmtp` when those tools are missing
4. Manual selection of a writable music folder exposed by another MTP app or mounted volume

This app is for local audio files that you own and are allowed to copy. Subscription/offline-cache tracks from streaming services generally cannot be transferred.

## Requirements

- macOS 14+
- Xcode 15+
- Swift 5.9+

## Run

```bash
open Package.swift
```

Then select the `GarminMusicManager` scheme in Xcode and run.

Or from the command line:

```bash
swift run
```

## Usage

1. Connect your Garmin watch (if it mounts as a volume) or expose its music folder via an MTP tool.
2. Click **Refresh** in the sidebar to detect mounted Garmin volumes.
3. If no device appears, click **Choose Music Folder** and select the watch's music directory.
4. Add music via **Add Files**, **Add Folder**, or drag-and-drop.
5. Review compatibility warnings and select tracks to sync.
6. Click **Sync to Watch Folder** to preview, then confirm the transfer.

## Settings

Open **Garmin Music Manager → Settings** (⌘,) to configure:

- Overwrite policy (skip identical, replace, keep both)
- Folder organization (flat, by artist, by artist/album)
- M3U8 playlist generation

## Project structure

```
Sources/GarminMusicManager/
├── App/           — App entry point and AppModel
├── Models/        — GarminDevice, AudioTrack, SyncModels
├── Services/      — DeviceDetector, MusicScanner, SyncService, etc.
├── Persistence/   — SettingsStore (UserDefaults)
├── Views/         — SwiftUI views
└── Utilities/     — Formatters, FileNameSanitizer
```

## Package / distribute

```bash
make app                 # release .app in dist/ (ad-hoc sign, bundles libmtp when found)
make app-debug
```

**Developer ID signing** (optional):

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make app-signed
```

**Notarization** (optional, requires Developer ID + notarytool profile):

```bash
# One-time: xcrun notarytool store-credentials AC_PASSWORD --apple-id you@… --team-id TEAMID
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="AC_PASSWORD"
NOTARIZE=1 ./Scripts/package-app.sh
```

The packager copies `libmtp` + `libusb` into `Contents/Frameworks` and rewrites
the helper’s install names so end users do not need Homebrew for MTP.

## Roadmap

- Metadata editor
- Playlist import from Apple Music XML or `.m3u`
- MTP native in-place move when firmware supports it
