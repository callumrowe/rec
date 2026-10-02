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
rec transcribe [SESSION_DIR] # (re)transcribe a session into the vault (default: latest session)
             [--engine parakeet|whisper] [--channel mic|system|both]
rec config                   # choose the Obsidian vault; --vault PATH, --model v2|v3, --show
```

Sessions go to `~/Recordings/rec/<yyyy-MM-dd_HHmmss>/` (or `--out DIR`):

| file          | contents |
|---------------|----------|
| `mic.wav`     | built-in mic, 16 kHz mono 16-bit |
| `system.wav`  | everything the Mac plays, 16 kHz mono 16-bit (not in a dictation) |
| `session.json`| `mode: "dictation"` for `--dictate`, start timestamp (ISO 8601 + epoch ms), end, duration, frame count, device UIDs, event log (gaps, device loss, silence warnings) |
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
(date, duration, mic, speakers, session path, model, `tags: [transcript]`)
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
- Re-running `rec transcribe` on a session overwrites that session's note.
  It runs from the CLI, not Rec.app, so writing into a vault under `~/Documents`
  uses your terminal's file access.

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
