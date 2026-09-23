import Foundation

let usage = """
usage: rec start [--out DIR] [--mic NAME|UID] [--detach]
                                          record mic + system audio until `rec stop` / Ctrl-C
       rec stop                           stop the running recording
       rec status                         show whether a recording is running
       rec devices                        list input devices for --mic
       rec verify [DIR]                   check a session (default: latest) for length, silence, sync

The mic defaults to the built-in MacBook mic. --mic (or REC_MIC) picks another by name
substring or UID; either way it is pinned and never follows the system default input.

Sessions go to ~/Recordings/rec/<timestamp>/ as mic.wav, system.wav (16 kHz mono) and session.json.
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "start": Launcher.start(Array(args.dropFirst()))
case "stop": Launcher.stop()
case "status": Launcher.status()
case "devices": Launcher.devices()
case "verify": Verify.run(Array(args.dropFirst()))
case "_record" where (2...3).contains(args.count):
    Recorder(dir: URL(fileURLWithPath: args[1]), micUID: args.count == 3 ? args[2] : nil).run()
case nil, "-h", "--help", "help": print(usage)
default: fail("unknown command \(args[0])\n\(usage)", code: 64)
}
