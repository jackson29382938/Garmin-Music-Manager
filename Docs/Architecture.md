# Architecture Notes

## MVP approach

The first version is intentionally simple:

1. Scan `/Volumes` for Garmin-like mounted devices.
2. Allow manual selection of a writable destination folder.
3. Scan a local music folder for common audio files.
4. Inspect basic metadata with AVFoundation.
5. Flag likely compatibility problems.
6. Copy selected tracks into a managed folder on the destination.
7. Generate an `.m3u8` playlist in the same folder.

## Why manual destination selection matters

Many Garmin watches use MTP instead of USB Mass Storage. macOS does not always mount MTP devices as regular file-system volumes. Until the app has an MTP backend, the manual folder picker is the safest workflow.

## Current modules

The MVP is currently contained in `Sources/GarminMusicManager/main.swift`:

- `ContentView`: primary SwiftUI interface
- `TrackRow`: row UI for each candidate track
- `AppViewModel`: app state and user actions
- `GarminVolumeScanner`: mounted-volume detection
- `MusicInspector`: local audio scanning and metadata inspection
- `FileNameSanitizer`: safe destination filenames

This should be split into separate files once the MVP builds cleanly.

## Next technical steps

### 1. MTP backend

A true Garmin Express-style local music manager needs MTP support. Possible approaches:

- Bridge to `libmtp`
- Shell out to an installed MTP utility
- Use a bundled helper process
- Keep the UI native while isolating device I/O behind a protocol

Suggested abstraction:

```swift
protocol DeviceFileSystem {
    func listMusicFolders() throws -> [DeviceFolder]
    func copyFile(from sourceURL: URL, to folder: DeviceFolder) throws
    func removeFile(_ file: DeviceFile) throws
    func freeSpace() throws -> Int64?
}
```

### 2. Audio conversion

Add a conversion pipeline so unsupported/lossless files can be converted into a Garmin-friendly copy before sync. This should create a new user-approved copy and never modify the original library file.

### 3. Metadata editor

Add a lightweight metadata repair sheet for title, artist, album, and track number.

### 4. Sync preview

Before copying, show a dry-run summary:

- New files
- Existing files that will be skipped or replaced
- Estimated size
- Remaining free space, when available
