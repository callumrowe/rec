# rec

macOS meeting recorder, v1: capture only. Records the built-in mic and all system
audio into two time-aligned 16 kHz mono WAVs. Requires macOS 14.2 or later.

```
make install                 # builds build/Rec.app, copies to ~/Applications, links ~/.local/bin/rec
rec start                    # foreground, live levels; Ctrl-C or `rec stop` from anywhere to finish
rec start --detach           # background; output goes to <session>/rec.log
rec stop
rec verify [SESSION_DIR]     # length / silence / sync check (default: latest session)
```

Sessions go to `~/Recordings/rec/<yyyy-MM-dd_HHmmss>/` (or `--out DIR`):

| file          | contents |
|---------------|----------|
| `mic.wav`     | built-in mic, 16 kHz mono 16-bit |
| `system.wav`  | everything the Mac plays, 16 kHz mono 16-bit |
| `session.json`| start timestamp (ISO 8601 + epoch ms), end, duration, frame count, device UIDs, event log (gaps, device loss, silence warnings) |

## How it works

- **System audio:** a global mono `CATapDescription` process tap
  (`AudioHardwareCreateProcessTap`) inside a private aggregate device, clocked by
  the built-in speakers so it survives headphones coming and going.
- **Mic:** `AVAudioEngine` pinned to the built-in mic by device UID
  (`kAudioOutputUnitProperty_CurrentDevice`). It never follows the system default
  input. If the device goes away, the gap is logged and filled with silence,
  system audio keeps recording, and capture resumes when the same UID returns.
- **One timeline:** both tracks are positioned against a single `mach_absolute_time`
  start (t0) using each buffer's host timestamp. When a track falls behind, the
  missing time is filled with silence. When it runs ahead, the overlap is dropped
  (20 ms tolerance). On stop, both are padded or trimmed to the same end time, so
  lengths match to the frame.
- **Permissions:** `rec start` launches `Rec.app` through LaunchServices (`open`), so
  the app, not your terminal, owns the Microphone and System Audio Recording grants.
  A tap without permission records silence instead of failing, so a live RMS meter
  runs per track and warns if either stays below -80 dBFS for 10 s.

## Gotchas

- **Lid closed = silent mic.** In clamshell mode the MacBook hardware-mutes the
  built-in mic. rec logs this and warns, but it still records the built-in mic
  (by design).
- **Rebuilds and permissions.** The app is ad-hoc signed, so every build has a
  new signature. If a rebuilt Rec suddenly records silence, run
  `make reset-permissions` and approve the prompts again on the next `rec start`.
- `rec verify` measures sync by cross-correlating the tracks' energy envelopes.
  That only works when the mic can hear the speakers. With headphones, check by ear.
