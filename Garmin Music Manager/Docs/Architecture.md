# Architecture

## App layers

- `App/` — SwiftUI app entry, `AppModel` orchestration, coordinators
  - `SyncSessionController` — preview + sync session façade over `SyncCoordinator`
  - `SyncCoordinator` — mounted + MTP sync plans/execution, conversion prep
  - `DeviceSessionController` — browse/upload/delete/move task lifecycle + device helpers
  - `MacLibrarySession` — Mac import/scan, selection helpers, Apple Music plans, queue restore
  - `DeviceLibraryCoordinator` — browser configuration + duplicate detection
  - `DeviceOperationsCoordinator` — pure helpers (upload builders, delete policy, paths)
  - `LibraryImportCoordinator` — expand folders/playlists + merge helpers (used by MacLibrarySession)
  - `TransferLogStore` — capped transfer log
- `Views/` — simplified shell: **Transfer** / **On Watch** / **Settings**
  - `ContentView` — mode picker, **global** `UserNoticeBanner`, sticky progress while sending, sheets
  - `TransferHomeView` — connection recovery, import cards, queue, Send, full activity log
  - `OnWatchView` + `DeviceContentsView` — device file manager (direct add = no playlist)
  - `SettingsView` — sync policies, destination, MTP install, performance, browser options
  - `SyncPreviewSheet` / `AppleMusicBrowserView` — modal flows
  - Shared chrome: `AppTheme`, `StatChip`, `PanelHeader`, `AppLogoMark`, `UserNoticeBanner`
- `Models/` — devices, tracks, sync jobs, storage info
- `Services/` — detection, scanning, sync, MTP client/transport, conversion
- `Stores/` — `DeviceBrowserStore` for mounted-folder and MTP backends (source of truth for device listings)
- `Persistence/` — `SettingsStore` + `LibraryQueueStore` (Mac queue paths/selection)
- `Utilities/` — formatters and filename sanitization

`AppModel` remains the composition root and holds UI-published state. Long-running
device work is owned by `DeviceSessionController` (tasks, MTP move originals,
cancel). Sync work is owned by `SyncSessionController`. Mac library import /
Apple Music / queue restore is owned by `MacLibrarySession`.

## Core package (`GarminMusicCore`)

Shared models, MTP request/response protocol, retry policy, path sanitization,
M3U writer, and compatibility evaluation used by both the app and `GarminMTPHelper`.

## Transfer model

The app writes to a user-visible folder or syncs over MTP:

- mounted Garmin volume `Music` directory
- direct USB/MTP via long-lived `GarminMTPHelper` + libmtp
- any test folder

Sync creates a playlist subfolder and copies selected files there. Mounted
folders optionally get an `.m3u8` playlist with relative `#EXTINF` paths
(including artist/album subfolders). MTP syncs optionally create a **native**
device playlist (`LIBMTP_Create_New_Playlist`) from post-upload object IDs when
`writePlaylist` is enabled — including the all-skip-identical case (playlist
rebuild without re-transfer).

### Sync flow

```text
User selects tracks → beginSend / quickSendSelected
  → optional Send Preview (always-preview pref, free-space risk, replace/keep-both)
  → MTP: reuse fresh device listing when available (skip forced pre-list)
  → SyncCoordinator copies/uploads (async, cancellable, chunked for MTP)
  → TransferProgressSnapshot (N of M) → ContentView sticky bar + Transfer activity
  → Helper returns uploaded object IDs; playlist built without full re-list when possible
  → M3UWriter .m3u8 (mounted)  OR  createPlaylist via helper (MTP)
  → DeviceBrowserStore refreshes destination listing at most once for UI
  → UserNotice (View on Watch / Retry failed)
```

`listMusic` does **not** download on-device `.m3u`/`.m3u8` bodies by default
(`includePlaylistContents: false`); that was a major cost on Forerunner-class MTP.
The helper also caches the last music snapshot for the warm session until a write.

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
├── MTPDirectSession.swift  — libmtp session / list / upload / delete / playlists
├── MTPDirectStatus.swift   — dependency diagnostics
├── MTPProgressReporter.swift — NDJSON progress + libmtp trampoline
├── MTPCancelState.swift    — SIGUSR1 cooperative cancel
└── MTPHelperModels.swift   — folder index, file records, path helpers
```

### Playlists

| Destination | Behavior when “Write playlist after sync” is on |
|-------------|--------------------------------------------------|
| Mounted folder | Writes `.m3u8` beside tracks with **correct relative subfolder paths** |
| MTP | After upload/refresh, creates or **updates** a native playlist by name (`LIBMTP_Create_New_Playlist` / `LIBMTP_Update_Playlist`) |

MTP playlist objects use C heap allocation (`strdup` / `malloc`) so `LIBMTP_destroy_playlist_t` can `free()` them safely. Playlist/track/file lists returned by libmtp are walked node-by-node when freeing (destroy helpers free one node only).

Local `.m3u` / `.m3u8` files can be imported into the Mac queue (local paths only).

## Safety rules

- Never delete watch files without explicit confirmation.
- Default to copying into an app-created subfolder.
- Generate playlists with relative paths.
- Keep a timestamped transfer log (capped at 500 lines).
- Warn if selected tracks exceed available storage.
- Serialize MTP helper invocations to avoid concurrent USB access.
- Warn if Garmin Express or Android File Transfer may be holding the MTP device.
- Idle-release the long-lived helper so other apps can claim the device.

## Progress streaming

Helper → app progress uses NDJSON **before** the final result line:

```text
{"progress":{"phase":"upload","itemIndex":0,"itemCount":3,"itemName":"a.mp3","bytesTransferred":1024,"bytesTotal":5000000,"overallFraction":0.05,"message":"…"}}
{"progress":{…}}
{"ok":true,"operationResult":{…}}
```

- libmtp `LIBMTP_progressfunc_t` drives per-byte updates during `Send_File` / `Get_File`
- `MTPProgressReporter` throttles (~80ms / 1% delta) and always emits item start/finish
- `PersistentMTPHelperTransport` reads lines until a final `ok`/result payload
- `DeviceBrowserStore` + `SyncCoordinator` remap chunk-local fractions into overall plan progress
- UI: determinate bars in the transfer panel and device operation banner

## Cancel mid-transfer

User Cancel → `Task.cancel` + `MTPHelperClient.cancelInFlightHelper()`:

1. Transport sends **SIGUSR1** to the helper (cooperative)
2. Helper `MTPCancelState` flips; libmtp progress callback returns `1` → abort current file
3. Between files, upload/download **break** (do not throw) so prior successes return as a normal `DeviceFileOperationResult` with a “Cancelled after N…” message
4. Mid-file cancel marks that item failed, then breaks with partial successes preserved
5. Client: pure cancel with zero progress → `CancellationError`; partial success + cancel → returns the result
6. `SyncCoordinator` credits partial results and stops remaining chunks (`wasCancelled`)
7. If still stuck after ~2.5s, transport escalates to SIGTERM/SIGKILL

See [DeviceQAChecklist.md](DeviceQAChecklist.md) for manual cancel verification.

## MTP readiness (brew-free packaged apps)

`MTPDependencyStatus.isReady` is true when:

1. `GarminMTPHelper` is findable (bundled in the `.app`, next to the binary, or under `.build/`), **and**
2. libmtp is loadable either as **bundled** `Contents/Frameworks/libmtp*.dylib` **or** a system/Homebrew dylib

Headers are a **build** dependency only and are not required at runtime. Packaged
apps therefore work on machines without Homebrew. “Install MTP” is offered only
when `canInstallViaHomebrew` is true (no bundled libmtp).

## Packaging

`Scripts/package-app.sh` builds the `.app`, optionally bundles `libmtp`/`libusb`
into `Contents/Frameworks`, signs inside-out (dylibs → helper → app), and can
submit to Apple notarization when `NOTARIZE=1` + `CODESIGN_IDENTITY` +
`NOTARY_PROFILE` are set.

## Performance settings (user-tunable)


`PerformanceSettings` (Settings → Performance) exposes transfer knobs with **named presets** and wide ranges. Balanced defaults match historical constants.

### Named presets

| Preset | Intent |
|--------|--------|
| **Balanced** | Shipping default |
| **Fast** | Large batches, long keep-alive, short timeouts, no verify, 128 kbps AAC |
| **Reliable** | Force re-list, batch 1, more retries, patient timeouts |
| **Express-friendly** | Short MTP keep-alive so other apps can claim USB |
| **Small files** | 128 kbps AAC + compress files over 50 MB |
| **Custom** | Any manual mix |

Selecting a preset replaces all knobs. Editing any control → Custom. Matching is value-based (`matchingPreset(for:)`).

### Knobs

| Knob | Default | Wired to |
|------|---------|----------|
| Listing reuse TTL | 120s (`0` = never) | `DeviceBrowserStore.listingReuseTTL` |
| Force re-list before sync | Off | `SyncSessionController.runMTP` |
| MTP session keep-alive | 90s | `PersistentMTPHelperTransport.idleTimeout` |
| Upload batch size | 5 (1…50) | `SyncCoordinator` + `MTPHelperClient` |
| Auto-detect + USB poll | On, 6s | `DeviceConnectMonitor` |
| AAC bitrate | 256 (64…320) | `AudioConverter` |
| MTP retries / backoff | 3 / 0.8s | `MTPRetryPolicy` via `MTPHelperClient.configure` |
| Timeout scale | 1.0× | Multiplies listing/op timeouts |
| Compress large files | Off | `SyncCoordinator.prepareTracks` |
| Include playlist contents | Off | MTP `listMusic(includePlaylistContents:)` |
| Verify uploads | On | `MTPHelperRequest.verifyUploads` → helper |

`resetAppState` keeps performance prefs. **Restore Balanced defaults** / `resetAllSettings` restore Balanced.

### Library / Conversion / Lifecycle (big ship)

| Group | Examples |
|-------|----------|
| **Library** | Restore queue, import selection, skip/auto-deselect duplicates, match mode + duration tolerance, fast import + concurrency, large-file warning MB, storage exceed policy, default sort, remember app mode |
| **Conversion** | AAC sample rate, keep/clear conversion cache, custom ffmpeg path, treat WAV as convertible |
| **Lifecycle** | Refresh after send, release helper after send, remote music root, playlist update vs create, auto-retry failed, notify on finish |

Persisted as JSON blobs (`librarySettings.v1`, `conversionSettings.v1`, `lifecycleSettings.v1`) plus existing performance keys.

## P1 product behaviors

- **Retry / continue** — after partial MTP transfer or cancel, failed **and** not-yet-attempted track IDs are retained (`retryTrackIDs`); UI re-selects and sends them.
- **Playlist update** — native MTP playlists with the same name are updated via `LIBMTP_Update_Playlist` instead of always creating a new one.
- **USB auto-detect** — `DeviceConnectMonitor` watches volume mount/unmount and polls Garmin USB signatures (interval from Performance settings, default ~6s).
- **Smarter duplicates** — `TrackMatching` uses name+size, title+artist+size, or title+duration+size.
- **Queue restore** — Mac track queue paths/selection are saved to `UserDefaults` and restored on launch when files still exist.

## Transfer entry points

| UI action | Entry | Engine |
|-----------|--------|--------|
| **Send to Watch** | `beginSend()` → preview policy → `sync()` | `SyncSessionController.run` |
| **Send without Preview** | `quickSendSelected()` / `uploadSelectedTracksToDevice()` | same `sync()` / `run` (storage-gated) |
| **Add files (no playlist)** On Watch | `uploadFilesToDevice` | direct browser upload — **not** playlist/convert/overwrite |

Do not reintroduce a second MTP plan/execute path for playlist send; it drifts from convert / overwrite / playlist behavior.

Completion UX: `TransferCompletionNotice` + global banner; device ops use `handleDeviceOpLog` for success/failure notices.

## Development hygiene

- Prefer **one writer** on this tree when large refactors are in flight (avoid half-wired untracked modules).
- New controllers (`SyncSessionController`, `DeviceSessionController`) should be **wired and tracked in git** in the same change set that introduces them—or deleted.
- Keep packaging version in `VERSION` (semver); tag releases `vX.Y.Z`.
- Run the [Device QA checklist](DeviceQAChecklist.md) against a real watch after MTP helper changes.
- Production MTP path uses direct libmtp only (legacy CLI output parsers were removed).

## Remaining roadmap

- **Metadata editor** — lightweight tag repair sheet
- **Apple Music XML playlist import** — beyond `.m3u` / Music.app browser
- **MTP move** — native in-place move when firmware supports it
