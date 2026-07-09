# Device QA checklist

Manual verification matrix for Garmin Music Manager. CI cannot exercise live USB/MTP; run these before a release or after MTP helper changes.

## Setup

- macOS 14+
- Packaged app (`make app`) or `swift run` with libmtp installed
- Data USB cable; wake the watch and unlock it
- Close Garmin Express, Android File Transfer, and OpenMTP before tests

## Scenarios

### 1. Connect — mounted volume (if the watch mounts)

1. Plug in; click **Refresh** on Transfer.
2. Destination shows the Music folder path.
3. **On Watch** lists existing audio.

### 2. Connect — MTP-only (no `/Volumes` mount)

1. Plug in; **Refresh**.
2. USB device name appears; destination is `Garmin MTP: … / Music` when MTP is ready.
3. **On Watch** → Refresh loads the library (may take 30–120s on first open).

### 3. Import + Send (5 tracks)

1. Add five local MP3/M4A files (or Apple Music local tracks).
2. Select all ready; **Send to Watch** (preview on or off).
3. Progress shows N of M and track names.
4. On Watch shows the new files; playlist appears when “Write playlist” is on.

### 4. Cancel mid-transfer

1. Start a multi-file MTP send (10+ tracks).
2. Cancel after 2–3 files finish.
3. **Expect:** banner/log says cancelled after N successes; those N remain on the watch.
4. On Watch listing refreshes; playlist may update for tracks that already sent (if write playlist is on).
5. **Retry / continue send** re-selects failed **and** not-yet-attempted tracks.
6. **Must not:** claim zero uploads when files clearly landed on the watch.

### 5. Replace policy + playlist update

1. Send a playlist once.
2. Change one track’s file (same name, different size) or use Replace policy.
3. Send again with the same playlist name.
4. **Expect:** replace deletes old object then uploads; native playlist updates (not a second empty playlist).

### 6. Device busy

1. Open Garmin Express (or another MTP client) and claim the watch.
2. Refresh / list / send in this app.
3. **Expect:** friendly “Watch is busy” notice (close Express / reconnect), not a raw libusb dump only.

### 7. Delete + copy to Mac

1. On Watch, select a test track → Delete (confirm).
2. Select another → Copy to Mac → file appears in chosen folder.

### 8. ALAC/FLAC conversion

| ffmpeg | Convert toggle | Expect |
|--------|----------------|--------|
| Missing | Off | Blocked help suggests enabling convert |
| Missing | On | Warning on Transfer Advanced + Settings; convert failures in activity log |
| Installed | On | ALAC/FLAC convert to AAC and send |

### 9. Retry / continue send

1. Force a partial failure or cancel mid multi-chunk send.
2. **Retry / continue send** re-selects failed + remaining IDs and previews/sends them.
3. After a clean full send, the button should be disabled.

### 10. Performance presets

1. Settings → Performance → **Reliable** (batch 1, force refresh).
2. Send a few tracks; confirm still works (slower is OK).
3. Restore **Balanced**.

## Sign-off

| Item | Pass? | Watch model / notes |
|------|-------|---------------------|
| Connect MTP | | |
| List music | | |
| Multi-file send | | |
| Cancel mid-batch | | |
| Playlist create/update | | |
| Busy device UX | | |
| Delete / copy to Mac | | |
| Conversion path | | |

Link from [Architecture.md](Architecture.md).
