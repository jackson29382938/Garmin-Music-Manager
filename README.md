# Garmin Music Manager

The canonical macOS app lives in **[Garmin Music Manager/](Garmin%20Music%20Manager/)**.

Open `Garmin Music Manager/Package.swift` in Xcode (macOS 14+) or run:

```bash
cd "Garmin Music Manager"
swift run
```

## What’s in this repo

| Path | Purpose |
|------|---------|
| [Garmin Music Manager/](Garmin%20Music%20Manager/) | Full SwiftUI app — MTP, Apple Music, device browsing, sync |
| `LICENSE` | MIT license |

## Features (full app)

- Garmin volume and USB/MTP device detection
- Long-lived `GarminMTPHelper --serve` for libmtp (session reuse, chunked uploads, retries)
- Apple Music library import via `iTunesLibrary`
- Sync preview, overwrite policies, M3U8 playlists (mounted folders)
- Optional ALAC/FLAC → AAC conversion when ffmpeg is installed
- Device file browser (music + optional advanced storage)

See [Garmin Music Manager/README.md](Garmin%20Music%20Manager/README.md) for usage and settings.

CI builds from the repo root and runs SwiftPM inside `Garmin Music Manager/`.
