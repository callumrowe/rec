# rec

macOS meeting recorder. Records the built-in mic and all system audio into two
time-aligned 16 kHz mono WAVs, then transcribes them on-device with
[FluidAudio](https://github.com/FluidInference/FluidAudio) into an Obsidian vault.
Requires macOS 14.2 or later.

```
make install                 # builds build/Rec.app, copies to ~/Applications, links ~/.local/bin/rec
rec start                    # asks which mic, then records with live levels; Ctrl-C or `rec stop` to finish
rec start --detach           # background; output goes to <session>/rec.log
rec start --mic streamcam    # skip the question (name substring or UID); --yes takes the default
rec start --dictate          # mic only, for thinking aloud; becomes a Dictation note
rec devices                  # list inputs, their UIDs, and which one rec would default to
rec stop
rec verify [SESSION_DIR]     # length / silence / sync check (default: latest session)
rec open                     # open ~/Recordings/rec in Finder
rec import                   # pick a Voice Memo, import it as a session and transcribe it
rec import FILE              # any audio or video file (drag it into the terminal)
             [--memo latest] [--as dictation|conversation] [--title TEXT] [--no-transcribe]
rec transcribe [SESSION_DIR] # (re)transcribe a session into the vault (default: latest session)
             [--engine parakeet|whisper] [--channel mic|system|both]
rec config                   # choose the Obsidian vault; --vault PATH, --model v2|v3, --show
```

Sessions go to `~/Recordings/rec/<yyyy-MM-dd_HHmmss>/` (or `--out DIR`):

| file          | contents |
|---------------|----------|
| `mic.wav`     | built-in mic, 16 kHz mono 16-bit (not in an import) |
| `system.wav`  | everything the Mac plays, 16 kHz mono 16-bit (not in a dictation or an import) |
| `audio.wav`   | an import's audio, mixed to 16 kHz mono 16-bit |
| `session.json`| `mode: "dictation"` for `--dictate` or `"import"` (with `source`: original path, memo ID, title), start timestamp (ISO 8601 + epoch ms), end, duration, frame count, device UIDs, event log (gaps, device loss, silence warnings) |
| `talk.json`   | a meeting's VAD timeline: speech regions per track, your turns and the talk stats (see [Talk time](#talk-time)) |
| `transcribe.log` | transcription progress and FluidAudio / Core ML diagnostics |
| `transcript.<engine>.json` | words (per track), speakers, turns and timings from the last run of that engine |

## Transcription

The first `rec start` asks which Obsidian vault to use (it lists the vaults
Obsidian knows about, or takes a path; the folder must contain `.obsidian/`),
creates `<vault>/transcriptions/` and saves the choice to
`~/.config/rec/config.json`. `rec config` changes it later.

When a recording stops it is transcribed. If `rec start` is running in the
foreground, the transcription happens in that terminal (whether you pressed Ctrl-C
there or ran `rec stop` elsewhere): it shows each step with a spinner and
elapsed time, and the prompt comes back once the note is written. Ctrl-C again
cancels it (`rec transcribe` picks it up later); closing the terminal doesn't.
A `--detach`ed recording is transcribed in the background instead, and a
notification says when the note is ready. Either way the note is
`<vault>/transcriptions/2026-09-23 14-30 Transcript.md`, with YAML frontmatter
(date, duration, mic, speakers, session path, model, `tags: [transcript]`,
and the [talk stats](#talk-time) `my_talk_ratio`, `longest_turn`, `turns_over_90s`)
and one line per turn:

```
**[00:03:12] Me:** Let's move the launch to Monday if Thursday slips.

**[00:03:18] Speaker 2:** That works for me.
```

- **ASR:** Parakeet TDT 0.6B via FluidAudio, run separately on each track.
  `v2` (English, default) or `v3` (25 European languages; `rec config --model v3`).
  Models download once (~470 MB) to `~/Library/Application Support/FluidAudio/`.
- **Speakers:** `mic.wav` is "Me". `system.wav` goes through FluidAudio's
  offline diarizer (pyannote segmentation + VBx clustering); one remote voice is
  "Them", several are "Speaker 1, 2…" in order of first speech. Each sentence
  gets the speaker most of its words fall in, so labels don't flip mid-sentence.
- **Echo:** without headphones the mic also hears the call. Mic words that the
  system track said at the same moment (±0.8 s) are dropped, so remote speech
  isn't duplicated as "Me".
- **A/B engines:** `--engine whisper` swaps Parakeet for WhisperKit
  large-v3-turbo (downloads ~1.6 GB once to `~/Documents/huggingface/`; the first
  load compiles it for the Neural Engine, which takes several minutes). Whisper
  invents text over silence, so FluidAudio's Silero VAD cuts each track into
  speech regions first and only those go to Whisper; word times are mapped back
  to the session timeline. `--channel mic|system` transcribes one track.
  Every run writes `<session>/transcript.<engine>.json` (same schema for both
  engines, so they sit side by side) and prints each engine's wall-clock time.
  Only the default run (Parakeet, both tracks) writes the vault note.
- **Dictation:** `rec start --dictate` records only the mic: no system tap, no
  test chime, one level meter. It's transcribed the same way (Parakeet on
  mic.wav, no diarization or echo removal) into
  `<vault>/transcriptions/2026-10-02 09-15 Dictation.md`, whose frontmatter has
  `type: dictation` and `tags: [dictation]` instead of `speakers`, and whose
  paragraphs carry a timestamp but no speaker name:

  ```
  ---
  date: 2026-10-02T09:15:00-04:00
  duration: "00:04:12"
  type: dictation
  tags:
    - dictation
  model: parakeet-tdt-0.6b-v2
  ---

  **[00:00:01]** So the thing I keep coming back to is…
  ```

  `rec transcribe` and `rec verify` read the mode from `session.json`, so they
  need no flag.
- **Imports:** `rec import` with no file lists the Voice Memos on this Mac
  (read from `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`),
  newest first, with ✓ on ones already imported; `--memo latest` skips the list.
  Reading that folder may need Full Disk Access for your terminal; exporting the
  memo and passing the file always works. A file can be anything AVFoundation
  decodes (m4a, mp3, wav, aiff, caf, or a video's sound). Every audio track is
  mixed to mono, resampled to `audio.wav` in a session named after when it was
  recorded (the memo's date, else the file's creation date), and transcribed
  straight away like a recording that just stopped. The original isn't copied;
  importing the same memo or file again finds its session.
  There's no "Me" in an import: `audio.wav` is diarized like system audio. One
  voice makes a Dictation note; several make a Transcript with "Speaker 1, 2…".
  `--as dictation|conversation` overrides that (on `rec import` or later on
  `rec transcribe`, and it's remembered in `session.json`). A memo you named, or
  `--title`, names the note (`2026-10-08 12-41 Little Ruby's Cafe.md`) and goes
  in the frontmatter as `title`, next to `source:` (the original file).
  Imported sessions are dated when they were recorded, so a plain
  `rec transcribe` (latest session) may not pick one; pass its directory.
- Re-running `rec transcribe` on a session overwrites that session's note.
  It runs from the CLI, not Rec.app, so writing into a vault under `~/Documents`
  uses your terminal's file access.

## Talk time

While a meeting records, a dot in the menu bar shows how long your current turn has
lasted: a hollow ring while you're not talking, green while you are, amber from 60 s,
red from 90 s, with the elapsed seconds beside it. There are no notifications,
sounds or popups. The dot is a status item, not a window, so sharing a window never
shows it. It also asks to be left out of full-screen captures, but whether that's
honoured depends on the sharing app.

- FluidAudio's Silero VAD runs on both tracks in 256 ms chunks, on its own task:
  the track writers only copy samples into a buffer for it, so it can't stall capture.
  If the VAD falls more than 30 s behind, the oldest audio is skipped (counted as
  silence). If the model fails to load or errors, the dot disappears and recording
  and transcription carry on as usual.
- Your turn starts when the mic has speech. Pauses shorter than 2 s keep the turn
  going. It ends at your last speech once you've been quiet for 2 s or the system
  track has had speech for 1 s (so an "mm-hm" doesn't end it).
- Echo: mic speech while the system track is speaking, or within ~0.5 s after,
  is treated as the call coming through your mic, not you.
- On stop the timeline is saved to `talk.json` and summarised
  (`talk  you 63% · longest 04:45 · 5 turns over 90s`). The note's frontmatter gets
  `my_talk_ratio` (your speech as a % of all speech), `longest_turn` (mm:ss) and
  `turns_over_90s`. A meeting without `talk.json` (recorded before this, or the
  live VAD failed) is measured from its WAVs during `rec transcribe`. Dictations and
  imports don't get the dot or the stats.
- Settings go in `~/.config/rec/config.json` under `talk` (all optional; these are the defaults):

  ```json
  "talk": {"enabled": true, "amberSeconds": 60, "redSeconds": 90,
           "gapSeconds": 2, "interruptSeconds": 1, "showSeconds": true}
  ```

  `turns_over_90s` always counts turns over 90 s, whatever `redSeconds` is.

## How it works

- **System audio:** a global mono `CATapDescription` process tap
  (`AudioHardwareCreateProcessTap`) inside a private aggregate device, clocked by
  the built-in speakers so it survives headphones coming and going.
- **Terminal output:** colour and the live meter only when stdout is a terminal;
  `NO_COLOR=1` turns colour off, and logs/pipes get plain text. Session events in
  `session.json` are always plain.
- **Mic choice:** `rec start` lists connected inputs (↑/↓ or 1–9, Enter, Esc to cancel). Enter accepts the default:
  `REC_MIC` if it's connected, else the built-in mic, else (lid closed) the best
  external mic (USB, then Bluetooth). Picking the built-in mic with the lid closed
  asks for confirmation. Without a terminal, the default is used automatically.
- **Startup check:** within about 4 s the recorder prints ✓/✗ for each track. The mic
  must deliver something above digital silence. For system audio it plays a quiet
  "Tink" and checks the tap captured it, because a tap without permission returns
  silence that looks exactly like "nothing playing".
- **Mic:** `AVAudioEngine` pinned by device UID to the chosen mic
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
  built-in mic. rec's default skips it when the lid is closed, and asks before
  using it anyway.
- **Rebuilds and permissions.** The app is ad-hoc signed, so every build has a
  new signature. If a rebuilt Rec suddenly records silence, run
  `make reset-permissions` and approve the prompts again on the next `rec start`.
- `rec verify` measures sync by cross-correlating the tracks' energy envelopes.
  That only works when the mic can hear the speakers. With headphones, check by ear.
