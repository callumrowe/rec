import Foundation

let usage = """
usage: rec start [--out DIR] [--mic NAME|UID] [--yes] [--detach]
                                          record mic + system audio until `rec stop` / Ctrl-C
       rec stop                           stop the running recording
       rec status                         show whether a recording is running
       rec devices                        list input devices for --mic
       rec verify [DIR]                   check a session (default: latest) for length, silence, sync
       rec open                           open the recordings folder in Finder
       rec transcribe [DIR]               transcribe a session (default: latest) into the Obsidian vault
       rec config [--vault PATH] [--model v2|v3] [--show]
                                          choose the Obsidian vault (and Parakeet model) for transcripts

`rec start` asks which mic to use. Enter accepts the default: REC_MIC if it's connected,
else the built-in mic, else (lid closed) the best external mic. --mic NAME|UID skips the
question; --yes takes the default. The mic is pinned for the whole session and never
follows the system default input.

Sessions go to ~/Recordings/rec/<timestamp>/ as mic.wav, system.wav (16 kHz mono) and session.json.
When a recording stops it is transcribed in the background (FluidAudio, on-device) into
<vault>/transcriptions/<yyyy-MM-dd HH-mm> Transcript.md. `rec start` asks for the vault on first use.
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "start": Launcher.start(Array(args.dropFirst()))
case "stop": Launcher.stop()
case "status": Launcher.status()
case "devices": Launcher.devices()
case "verify": Verify.run(Array(args.dropFirst()))
case "open": Launcher.openRecordings()
case "transcribe": Transcriber.run(Array(args.dropFirst()))
case "_transcribe" where args.count == 2: Transcriber.run([args[1]], background: true)
case "config": ConfigCommand.run(Array(args.dropFirst()))
case "_record" where (2...3).contains(args.count):
    Recorder(dir: URL(fileURLWithPath: args[1]), micUID: args.count == 3 ? args[2] : nil).run()
case nil, "-h", "--help", "help": print(usage)
default: fail("unknown command \(args[0])\n\(usage)", code: 64)
}
