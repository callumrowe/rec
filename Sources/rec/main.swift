import Foundation

let usage = """
usage: rec start [--out DIR] [--mic NAME|UID] [--yes] [--detach] [--dictate]
                                          record mic + system audio until `rec stop` / Ctrl-C
                                          (--dictate: mic only, transcribed as a dictation note)
       rec stop                           stop the running recording
       rec status                         show whether a recording is running
       rec devices                        list input devices for --mic
       rec verify [DIR]                   check a session (default: latest) for length, silence, sync
       rec open                           open the recordings folder in Finder
       rec import [FILE] [--memo latest]  turn a Voice Memo (picked from a list) or any audio/video file
         [--as dictation|conversation]    into a session and transcribe it; --as overrides the guess
         [--title TEXT] [--no-transcribe] from how many voices it hears
       rec transcribe [DIR]               transcribe a session (default: latest) into the Obsidian vault
         [--engine parakeet|whisper]      A/B another engine (Whisper runs on VAD speech regions only)
         [--channel mic|system|both]      one track; only parakeet + both writes the note
         [--as dictation|conversation]    for an import: override the note type
         [--split-gap 0.6]                a pause this long (seconds) starts a new line
         [--no-vocab]                     skip ~/.config/rec/vocab.json (boosting and alias fixes)
       rec config [--vault PATH] [--model v2|v3] [--show]
                                          choose the Obsidian vault (and Parakeet model) for transcripts

`rec start` asks which mic to use. Enter accepts the default: REC_MIC if it's connected,
else the built-in mic, else (lid closed) the best external mic. --mic NAME|UID skips the
question; --yes takes the default. The mic is pinned for the whole session and never
follows the system default input.

Sessions go to ~/Recordings/rec/<timestamp>/ as mic.wav, system.wav (16 kHz mono) and session.json.
When a recording stops it is transcribed (FluidAudio, on-device) into
<vault>/transcriptions/<yyyy-MM-dd HH-mm> Transcript.md. `rec start` asks for the vault on first use.
Names the models get wrong go in ~/.config/rec/vocab.json (created on first transcription):
[{"text": "Oskar", "aliases": ["Oscar"]}]
In the terminal running `rec start` the transcription runs right there with live progress
(Ctrl-C again cancels it); with --detach it runs in the background.
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "start": Launcher.start(Array(args.dropFirst()))
case "stop": Launcher.stop()
case "status": Launcher.status()
case "devices": Launcher.devices()
case "verify": Verify.run(Array(args.dropFirst()))
case "open": Launcher.openRecordings()
case "import": Importer.run(Array(args.dropFirst()))
case "transcribe": Transcriber.run(Array(args.dropFirst()))
case "_transcribe" where args.count == 2: Transcriber.run([args[1]], background: true)
case "config": ConfigCommand.run(Array(args.dropFirst()))
case "_record" where args.count >= 2:
    let rest = args.dropFirst(2)
    Recorder(dir: URL(fileURLWithPath: args[1]), micUID: rest.first { !$0.hasPrefix("-") },
             dictation: rest.contains("--dictate")).run()
case nil, "-h", "--help", "help": print(usage)
default: fail("unknown command \(args[0])\n\(usage)", code: 64)
}
