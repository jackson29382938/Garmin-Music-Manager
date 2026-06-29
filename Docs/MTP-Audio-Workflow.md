# MTP, Conversion, and Metadata Workflow

## What changed in this branch

The app is no longer just a simple folder copier. It now has separate layers for:

- Mounted Garmin/Finder-visible folder sync
- Experimental MTP detection and file sending through `libmtp` command-line tools
- Audio conversion through `ffmpeg`
- Metadata repair through `ffmpeg`
- Persistent debug logging for copy/paste troubleshooting

## Optional tools

The app runs without these tools, but advanced workflows depend on them:

```bash
brew install ffmpeg libmtp
```

Expected tools searched by the app:

- `ffmpeg`
- `mtp-detect`
- `mtp-files`
- `mtp-sendfile`

The app searches the normal shell `PATH` plus:

- `/opt/homebrew/bin`
- `/usr/local/bin`
- `/usr/bin`
- `/bin`

## MTP support

MTP support is intentionally marked experimental. macOS does not normally expose many Garmin watches as regular writable file-system volumes, so this branch adds a pragmatic backend that shells out to `libmtp` tools.

Current behavior:

1. **Detect MTP** runs `mtp-detect`.
2. It then tries `mtp-files` and writes a truncated listing into the debug log.
3. **Experimental MTP sync** uses `mtp-sendfile` for each selected track.

Known limitation: this first pass does not yet provide a native folder tree picker for the watch's internal MTP folders. Depending on how `libmtp` handles the connected watch, files may be sent to a default location rather than a precise `/Music` folder. That is why mounted-folder sync remains the safer default.

## Audio conversion

The **Convert Selected** button creates generated copies in:

```text
~/Library/Caches/GarminMusicManager/GeneratedAudio
```

It never overwrites the user's original library files.

Supported presets:

- AAC 192 kbps `.m4a`
- MP3 192 kbps `.mp3`

The converted copy becomes the file used for sync.

## Metadata repair

The **Repair Metadata** button opens a sheet for:

- Title
- Artist
- Album
- Track number

If `ffmpeg` is installed, the app writes a repaired copy in the generated audio cache and syncs that copy. If `ffmpeg` is missing, it still saves the edited metadata in app memory so filenames and playlist labels can use the corrected values, but it cannot rewrite embedded file tags.

## Debug log

The app now keeps both:

1. A visible in-app log
2. A persistent log file at:

```text
~/Library/Application Support/GarminMusicManager/Logs/debug.log
```

Use **Copy Debug Log** when asking for debugging help. It copies both the visible session log and persistent log content.

## Recommended next improvement

The next major step is replacing the `libmtp` command-line wrapper with a real MTP device abstraction that can:

- Enumerate MTP storage IDs
- Pick the exact Garmin music folder
- Upload playlists into that folder
- Report progress and free space from the device itself
