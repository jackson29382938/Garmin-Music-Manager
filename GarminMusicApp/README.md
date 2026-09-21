# Garmin Music Manager — cross-platform edition

A brand-new front-end for Garmin Music Manager, written in Swift with
[SwiftCrossUI](https://github.com/stackotter/swift-cross-ui). The **same code
runs natively on Windows, macOS, and Linux** — `DefaultBackend` renders through
WinUI on Windows, AppKit on macOS, and Gtk 4 on Linux. It reuses the portable
[`GarminMusicCore`](../Garmin%20Music%20Manager) engine (playlist parsing,
compatibility rules, path sanitizing, `.m3u8` writing) shared with the native
macOS app.

## What it does

- **Library** — point at a music folder; every file is checked against Garmin's
  format rules (MP3/M4A/AAC/WAV play; FLAC/ALAC/OGG/WMA/DRM are flagged) with
  Ready / Blocked badges and a running selection total.
- **Transfer** — copy the selected tracks into a destination folder (a mounted
  Garmin USB volume or any folder), with organization (flat / by artist /
  by artist·album), an overwrite policy, and an optional `.m3u8` playlist, with
  live progress.
- **On Watch** — browse what's currently in the destination folder.
- **Settings** — defaults and format help.

Everything here is platform-independent: no AVFoundation, iTunesLibrary, or
libmtp, so it behaves identically on all three desktops. (Direct USB/MTP and
Apple Music import remain in the native macOS app.)

## Build & run

Requires the [Swift toolchain](https://www.swift.org/install/) (6.x).

```sh
cd GarminMusicApp

# Windows / macOS: no extra system dependencies
swift run

# Linux: install GTK 4 first
sudo apt-get install -y libgtk-4-dev clang pkg-config
swift run
```

To force a particular backend (e.g. test the Gtk look on a Mac), set
`SCUI_DEFAULT_BACKEND=GtkBackend` before building.

## CI

`.github/workflows/app.yml` builds this app on `windows-latest` (WinUI),
`macos-latest` (AppKit), and Linux (Gtk) on every push and pull request.
