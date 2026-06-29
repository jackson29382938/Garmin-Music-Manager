# Garmin Music Manager

A lightweight macOS SwiftUI app for managing local music files on Garmin music watches.

## What it does

Garmin Express can be clunky for local music. This app is designed around a simpler, safer workflow:

1. Choose a Garmin watch destination or manually pick a mounted music folder.
2. Scan a local music folder or add individual files.
3. Review compatibility warnings before copying anything.
4. Search, filter, sort, and select the tracks you actually want.
5. Copy the selected files into a generated `GarminMusicManager` folder and write a matching `.m3u8` playlist.

## UI/UX refresh

The current interface is organized as a guided dashboard instead of a flat set of controls:

- **Workflow strip:** shows Destination → Library → Review → Sync progress so the user always knows the next step.
- **Watch destination card:** separates detected Garmin volumes from manual folder selection and shows the active path clearly.
- **Library card:** summarizes loaded track count, total duration, and transfer size.
- **Review card:** adds search, status filtering, sorting, status chips, clearer warning pills, and cleaner selected-row styling.
- **Sync preview card:** shows selected count, selected duration, transfer size, destination folder, progress, and the last sync result before/after copying.
- **Activity log card:** keeps technical status available without making it the main interface.

## Important limitation

Many Garmin music watches connect to macOS using MTP. macOS does not expose all MTP devices as normal Finder volumes, so a fully polished version will need a dedicated MTP backend. This starter app currently supports:

1. Garmin devices/folders that appear under `/Volumes`
2. Manual selection of a writable music folder exposed by another MTP app or mounted volume

This app is intended for local audio files that you own and are allowed to copy. Subscription/offline-cache tracks from streaming services generally cannot be transferred as normal files.

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

## Current status

This is an MVP seed project. It now has a more usable SwiftUI workflow for scanning, reviewing, filtering, selecting, and syncing local music files. True MTP browsing, conversion, metadata repair, and playlist imports are still future work.

## Planned next steps

- Add real MTP device browsing/copy support
- Add audio conversion support for unsupported files such as FLAC/ALAC/OGG/WMA
- Add stronger metadata repair/editing
- Add playlist import from Apple Music/iTunes XML or `.m3u` files
- Add duplicate detection
- Add safer dry-run sync preview before file writes
