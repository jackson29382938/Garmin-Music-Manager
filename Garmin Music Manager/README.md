# Garmin Music Manager

A native macOS SwiftUI app for managing local music files on Garmin music watches.

## Features

- **Simple shell:** Transfer · On Watch · Settings (primary **Send to Watch** action)
- **Device detection** — `/Volumes` Garmin mounts + USB/MTP (vendor `0x091e`) via libmtp
- **Fast MTP path** — long-lived `GarminMTPHelper --serve`; chunked uploads, retries, live progress, mid-file cancel
- **Partial cancel recovery** — successes kept on the watch; **Retry / continue send** covers failed + not-yet-attempted tracks
- **Portable MTP** — packaged app can bundle libmtp/libusb; optional Homebrew install from source builds
- **Import** — files, folders, drag-and-drop, `.m3u`/`.m3u8`, Apple Music (`iTunesLibrary`) local non-DRM tracks
- **Compatibility** — ALAC/FLAC conversion when ffmpeg is available; storage budget warnings
- **Sync policies** — overwrite, folder organization, native MTP playlists or `.m3u8` on mounted volumes
- **On Watch** — browse, delete, copy to Mac, move-within (copy + confirm delete)
- **Performance presets** — Balanced / Fast / Reliable / Express-friendly / Small files
- **Persistence** — settings + Mac queue restore

## Important limitation

Many Garmin music watches use **MTP**. macOS does not always expose them as Finder volumes. This app supports:

1. Mounted volumes under `/Volumes`
2. Direct MTP via bundled helper + libmtp
3. Manual destination folder

Local owned files only — not DRM/cloud streaming caches.

## Requirements

- macOS 14+
- Xcode 15+ / Swift 5.9+
- Source builds of the helper: `brew install libmtp`

## Run

```bash
open Package.swift
# or:
swift run
make app && open "dist/Garmin Music Manager.app"
```

## Project structure

```
Sources/
├── GarminMusicCore/       — shared models, MTP protocol, utilities
├── GarminMTPHelper/       — libmtp worker (--serve / one-shot)
├── CLibMTP/               — system libmtp shim
└── GarminMusicManager/
    ├── App/               — AppModel, sync/device/Mac library controllers
    ├── Models/            — tracks, devices, sync, performance, notices
    ├── Services/          — detector, MTP transport/client, planner, convert
    ├── Stores/            — DeviceBrowserStore
    ├── Persistence/       — SettingsStore, LibraryQueueStore
    ├── Views/             — Transfer / On Watch / Settings shell
    │   └── DeviceBrowser/ — toolbar + chrome for device file manager
    └── Utilities/
Tests/GarminMusicManagerTests/
Docs/
├── Architecture.md
└── DeviceQAChecklist.md   — manual watch matrix (run after MTP changes)
```

## Settings

**Garmin Music Manager → Settings** (also Transfer → Advanced):

- Overwrite / organization / write playlist / convert ALAC·FLAC
- Performance presets and knobs (batch size 1–50, keep-alive, retries, verify uploads, …)
- MTP backend status + Install MTP when needed
- ffmpeg status for conversion

## Package / distribute

```bash
make app                 # release .app in dist/
make app-signed          # requires CODESIGN_IDENTITY
# NOTARIZE=1 NOTARY_PROFILE=… for notarization
```

## Development

```bash
swift test
swift build -c release
```

After changing MTP helper/session code, run [Docs/DeviceQAChecklist.md](Docs/DeviceQAChecklist.md) on a real watch (especially cancel mid-transfer and Retry / continue).

See [Docs/Architecture.md](Docs/Architecture.md) for MTP design, cancel semantics, and transfer engine notes.

## Roadmap

- Metadata editor
- Apple Music XML playlist import
- Native MTP in-place move when firmware supports it

## Release checklist

1. Bump `VERSION` (semver) and tag `vX.Y.Z`
2. `make app` or `make app-signed`
3. Optional notarization
4. Device QA checklist on at least one music Garmin
