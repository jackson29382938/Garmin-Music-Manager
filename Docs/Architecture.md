# Architecture

## App layers

- `App/` — SwiftUI app entry, `AppModel` orchestration
- `Views/` — SwiftUI user interface (sidebar, track table, device contents, transfer panel, settings)
- `Models/` — lightweight data models for devices, tracks, sync jobs, and storage info
- `Services/` — device detection, library scanning, playlist writing, file copying, device content management
- `Persistence/` — `SettingsStore` backed by `UserDefaults`
- `Utilities/` — formatters and filename sanitization

## Transfer model

The app writes to a user-visible folder. The user can select:

- a mounted Garmin volume's `Music` directory,
- a visible MTP-exported `Music` directory,
- or any test folder.

Sync creates a subfolder named after the playlist and copies selected files there. It optionally writes an `.m3u8` playlist with `#EXTINF` entries using relative paths.

### Sync flow

```text
User selects tracks → Sync Preview (dry-run)
  → SyncService copies files (async, cancellable)
  → M3UWriter generates .m3u8
  → DeviceContentService refreshes destination listing
```

### Overwrite policies

| Policy | Behavior |
|--------|----------|
| Skip identical | Skip files with matching name and size |
| Replace | Overwrite existing files |
| Keep both | Copy with a unique renamed filename |

### Organization policies

| Policy | Target path |
|--------|-------------|
| Flat | `PlaylistName/track.mp3` |
| By artist | `PlaylistName/Artist/track.mp3` |
| By artist/album | `PlaylistName/Artist/Album/track.mp3` |

## MTP limitation

Many Garmin music watches on macOS are not mounted in Finder because they use MTP. A future version should use a helper process rather than putting MTP code directly into SwiftUI.

Suggested design:

```text
SwiftUI App
  → GarminMTPHelper CLI
      → libmtp / IOKit USB enumeration
      → device storage tree
      → upload/delete/list commands
```

Keeping MTP in a helper has advantages:

- easier crash isolation
- easier debugging with command-line logs
- simpler future code-signing entitlements
- can be replaced by different transfer backends later

Suggested abstraction:

```swift
protocol DeviceFileSystem {
    func listMusicFolders() throws -> [DeviceFolder]
    func copyFile(from sourceURL: URL, to folder: DeviceFolder) throws
    func removeFile(_ file: DeviceFile) throws
    func freeSpace() throws -> Int64?
}
```

## Safety rules

- Never delete watch files without explicit confirmation.
- Default to copying into an app-created subfolder.
- Generate playlists with relative paths.
- Keep a timestamped transfer log.
- Warn if selected tracks exceed available storage.
- Warn if Garmin Express or Android File Transfer may be holding the MTP device.

## Future work

- **MTP backend** — libmtp helper for watches invisible to macOS
- **Audio conversion** — ffmpeg pipeline for ALAC/FLAC → AAC/MP3
- **Metadata editor** — lightweight tag repair sheet
- **Playlist import** — Apple Music XML, `.m3u` files
- **App packaging** — signed/notarized `.app` bundle
