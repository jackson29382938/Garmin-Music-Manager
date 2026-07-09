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
| [Garmin Music Manager/Docs/Architecture.md](Garmin%20Music%20Manager/Docs/Architecture.md) | MTP design, cancel semantics, performance knobs |
| [Garmin Music Manager/Docs/DeviceQAChecklist.md](Garmin%20Music%20Manager/Docs/DeviceQAChecklist.md) | Manual watch QA matrix (run after MTP changes) |
| `LICENSE` | MIT license |
| `.github/workflows/build.yml` | CI: build + test inside the app package |

## Features

- Transfer · On Watch · Settings shell with **Send to Watch**
- Garmin volume + USB/MTP detection; long-lived helper with progress and mid-file cancel
- Partial cancel keeps successes; **Retry / continue send** for failed + remaining tracks
- Apple Music import, M3U playlists, optional ffmpeg conversion
- Performance presets (batch size, keep-alive, verify uploads, …)
- Packaged app can bundle libmtp/libusb

See [Garmin Music Manager/README.md](Garmin%20Music%20Manager/README.md) for usage, packaging, and release checklist.

## Requirements

- macOS 14+
- Xcode 15+ / Swift 5.9+
- Source builds: libmtp via Homebrew

## Versioning

Packaged version comes from `Garmin Music Manager/VERSION`. Tag releases as `v0.1.0`.
