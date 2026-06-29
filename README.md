# Garmin Music Manager

A lightweight macOS SwiftUI app for managing local music files on Garmin music watches.

## Goal

Garmin Express can be clunky for local music. This project aims to provide a cleaner workflow for:

- Scanning a local music folder
- Checking whether files look Garmin-compatible
- Warning about common problems like unsupported formats and missing metadata
- Choosing a connected Garmin watch or manually selecting a destination music folder
- Copying selected tracks to the watch
- Generating an `.m3u8` playlist for the copied tracks

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

This is an MVP seed project. It establishes the app architecture and a usable first UI before adding deeper metadata editing, conversion, and true MTP support.

## Planned next steps

- Add real MTP device browsing/copy support
- Add audio conversion support
- Add stronger metadata repair/editing
- Add playlist import from Apple Music/iTunes XML or `.m3u` files
- Add duplicate detection
- Add safer dry-run sync preview
