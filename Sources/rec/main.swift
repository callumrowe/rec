import Foundation

let usage = """
usage: rec start [--out DIR] [--detach]   record mic + system audio until `rec stop` / Ctrl-C
       rec stop                           stop the running recording
       rec status                         show whether a recording is running
       rec verify [DIR]                   check a session (default: latest) for length, silence, sync

Sessions go to ~/Recordings/rec/<timestamp>/ as mic.wav, system.wav (16 kHz mono) and session.json.
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "start": Launcher.start(Array(args.dropFirst()))
case "stop": Launcher.stop()
case "status": Launcher.status()
case "verify": Verify.run(Array(args.dropFirst()))
case "_record" where args.count == 2: Recorder(dir: URL(fileURLWithPath: args[1])).run()
case nil, "-h", "--help", "help": print(usage)
default: fail("unknown command \(args[0])\n\(usage)", code: 64)
}
