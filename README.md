# Garmin Music Manager

The canonical macOS app lives in **[Garmin Music Manager/](Garmin%20Music%20Manager/)**.

Open `Garmin Music Manager/Package.swift` in Xcode (macOS 14+) or run:

```bash
cd "Garmin Music Manager"
swift run
# or: make app && open "dist/Garmin Music Manager.app"
```

## What’s in this repo

| Path | Purpose |
|------|---------|
| [Garmin Music Manager/](Garmin%20Music%20Manager/) | Full SwiftUI app — MTP, Apple Music, device browsing, sync |
| `LICENSE` | MIT license |
| `.github/workflows/build.yml` | CI: build + test inside the app package |

## Features

- Garmin volume and USB/MTP device detection
- Long-lived `GarminMTPHelper --serve` (session reuse, chunked uploads, retries, live progress, mid-file cancel)
- Apple Music library import (`iTunesLibrary`) for local non-DRM tracks
- Import local tracks from `.m3u` / `.m3u8` playlists
- Sync preview, overwrite policies, artist/album folder organization
- Playlists: `.m3u8` on mounted folders; **native MTP playlists** when enabled
- Optional ALAC/FLAC → AAC conversion when ffmpeg is installed
- Device file browser (music + optional advanced storage)
- Packaged app can bundle libmtp/libusb (no Homebrew required on target Macs)

See [Garmin Music Manager/README.md](Garmin%20Music%20Manager/README.md) for usage, settings, packaging/notarization, roadmap, and the release checklist.

## Requirements

- macOS 14+
- Xcode 15+ / Swift 5.9+
- For source builds of the MTP helper: libmtp (e.g. `brew install libmtp`)

## Versioning

The packaged app version comes from `Garmin Music Manager/VERSION` (semver). Tag releases as `v0.1.0` so `git describe` matches. Untagged builds fall back to that file, then a git hash.
