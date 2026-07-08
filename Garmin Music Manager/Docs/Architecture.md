# Architecture

## App layers

- `App/` — SwiftUI app entry, `AppModel` orchestration, coordinators
  - `SyncCoordinator` — mounted + MTP sync plans/execution
  - `DeviceLibraryCoordinator` — browser configuration + legacy snapshot mapping
  - `DeviceOperationsCoordinator` — upload/delete/move helpers
  - `LibraryImportCoordinator` — Mac library import merge/scan helpers
  - `TransferLogStore` — capped transfer log
- `Views/` — SwiftUI user interface
- `Models/` — devices, tracks, sync jobs, storage info
- `Services/` — detection, scanning, sync, MTP client/transport, conversion
- `Stores/` — `DeviceBrowserStore` for mounted-folder and MTP backends
- `Persistence/` — `SettingsStore` (`UserDefaults`)
- `Utilities/` — formatters and filename sanitization

## Core package (`GarminMusicCore`)

Shared models, MTP request/response protocol, retry policy, path sanitization,
M3U writer, and compatibility evaluation used by both the app and `GarminMTPHelper`.

## Transfer model

The app writes to a user-visible folder or syncs over MTP:

- mounted Garmin volume `Music` directory
- direct USB/MTP via long-lived `GarminMTPHelper` + libmtp
- any test folder

Sync creates a playlist subfolder and copies selected files there. Mounted
folders optionally get an `.m3u8` playlist with relative `#EXTINF` paths.

### Sync flow

```text
User selects tracks → Sync Preview (dry-run)
  → SyncCoordinator copies/uploads (async, cancellable, chunked for MTP)
  → M3UWriter generates .m3u8 (mounted folders)
  → DeviceBrowserStore refreshes destination listing
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

## MTP architecture

Garmin watches that use MTP are handled via a helper subprocess, **not**
in-process libmtp calls from SwiftUI:

```text
SwiftUI App (AppModel)
  → DeviceBrowserStore
      → MTPDeviceFileSystem
          → MTPHelperClient (serialized via MTPOperationCoordinator)
              → PersistentMTPHelperTransport  (GarminMTPHelper --serve)
                  NDJSON request/response over a long-lived process
                  → MTPHelperRunner (reused MTPDirectSession)
                      → libmtp direct API
```

### Why a long-lived helper?

Previously every list/upload/delete **spawned a new process and re-opened USB**,
re-enumerating the whole device. That dominated total time and amplified
transient USB failures.

The persistent helper:

- keeps one MTP session open across browse → plan → multi-chunk upload
- caches folder indexes within the session
- verifies uploads via per-object metadata when possible (avoids full re-list)
- auto-retries transient USB errors once with a fresh session
- idles out after ~90s to release the device for other apps
- still provides crash isolation from the UI process

`MTPHelperClient` talks through `MTPHelperTransport`
(`PersistentMTPHelperTransport` in production; fakes in tests). One-shot
`SubprocessMTPHelperTransport` remains for fallback/tests.

Operations are cancellable end to end: cancelling the owning Swift Task removes
queued waiters from `MTPOperationCoordinator` and can terminate a stuck helper.

Uploads are chunked (default 5 files) for progress and partial recovery while
the same serve process stays warm.

When a sync replaces an existing file, the helper deletes the old copy
immediately before uploading its replacement (per item, via
`DeviceUploadFile.replaceObjectID`).

Raw libmtp/libusb error text is translated by `MTPErrorTranslator` and preserved
in `MTPHelperError.diagnosticDetail`.

Mounted folders use `MountedFolderDeviceFileSystem` implementing the same
`DeviceFileSystem` protocol.

### Helper module layout

```text
Sources/GarminMTPHelper/
├── HelperEntry.swift       — @main, one-shot + --serve loop
├── MTPHelperRunner.swift   — request dispatch + session reuse
├── MTPDirectSession.swift  — libmtp session / list / upload / delete
├── MTPDirectStatus.swift   — dependency diagnostics
└── MTPHelperModels.swift   — folder index, file records, path helpers
```

## Safety rules

- Never delete watch files without explicit confirmation.
- Default to copying into an app-created subfolder.
- Generate playlists with relative paths.
- Keep a timestamped transfer log (capped at 500 lines).
- Warn if selected tracks exceed available storage.
- Serialize MTP helper invocations to avoid concurrent USB access.
- Warn if Garmin Express or Android File Transfer may be holding the MTP device.
- Idle-release the long-lived helper so other apps can claim the device.

## Remaining roadmap

- **Metadata editor** — lightweight tag repair sheet
- **Playlist import** — Apple Music XML, `.m3u` files
- **Signed/notarized packaging** — distribution-ready `.app` bundle
- **MTP move** — copy-then-delete within a single helper session (partially done in app)
- **Progress callbacks from helper** — per-byte upload progress over NDJSON events
