# Garmin Music Manager

A macOS SwiftUI app for managing local music files on Garmin music watches.

## Goal

Garmin Express can be clunky for local music. This project aims to provide a cleaner workflow for:

- Scanning a local music folder
- Checking whether files look Garmin-compatible
- Warning about unsupported formats and missing metadata
- Choosing a connected Garmin watch or manually selecting a destination music folder
- Copying selected tracks to the watch
- Generating an `.m3u8` playlist for mounted-folder sync
- Converting selected tracks into Garmin-friendlier copies
- Repairing title/artist/album metadata before sync
- Copying/exporting a debug log when something fails

## Current capabilities

### Stable path: mounted folder sync

If the Garmin watch or an MTP helper exposes a writable folder, the app can:

1. Validate that the folder exists or can be created.
2. Verify it is writable.
3. Estimate selected track size.
4. Copy selected tracks into a managed `GarminMusicManager` folder.
5. Write a `GarminMusicManager.m3u8` playlist.

### Experimental path: MTP sync

Many Garmin music watches connect to macOS using MTP. macOS does not expose all MTP devices as normal Finder volumes, so this branch adds experimental `libmtp` command-line support.

The app can:

- Detect whether `mtp-detect`, `mtp-files`, and `mtp-sendfile` are available
- Run MTP device detection and log the result
- Try to send selected tracks through `mtp-sendfile`

This is still experimental because the first implementation does not yet include a native MTP folder picker for the watch's internal storage.

### Audio conversion

With `ffmpeg` installed, the app can create generated copies in:

```text
~/Library/Caches/GarminMusicManager/GeneratedAudio
```

Conversion presets:

- AAC 192 kbps `.m4a`
- MP3 192 kbps `.mp3`

Original library files are not modified.

### Metadata repair

The app includes a metadata repair sheet for:

- Title
- Artist
- Album
- Track number

With `ffmpeg`, it writes a repaired copy and syncs the copy. Without `ffmpeg`, it still uses edited values for filenames and playlist labels but cannot rewrite embedded tags.

### Debug logging

The app keeps a visible in-app log and a persistent log at:

```text
~/Library/Application Support/GarminMusicManager/Logs/debug.log
```

Use **Copy Debug Log** or **Export Debug Log** when debugging.

## Optional dependencies

For conversion, metadata repair, and experimental MTP:

```bash
brew install ffmpeg libmtp
```

The app searches your shell `PATH` plus common Homebrew paths.

## Requirements

- macOS 14+
- Xcode 15+
- Swift 5.9+

## Run

```bash
open Package.swift
```

Then select the `GarminMusicManager` scheme in Xcode and run.

You can also try:

```bash
swift run
```

## Docs

- `Docs/Architecture.md`
- `Docs/MTP-Audio-Workflow.md`

## Planned next steps

- Native MTP folder tree browsing
- Better device free-space reporting over MTP
- Playlist upload over MTP
- Conversion progress UI
- Duplicate detection
- Safer conflict resolution for existing watch files
