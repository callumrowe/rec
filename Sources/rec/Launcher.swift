import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/rec", isDirectory: true)
    static let pidFile = support.appendingPathComponent("recorder.pid")
    static let recordingsRoot = home.appendingPathComponent("Recordings/rec", isDirectory: true)
}

struct RunningRecorder {
    let pid: pid_t
    let dir: String
}

enum PIDFile {
    static func write(dir: URL) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? "\(getpid())\n\(dir.path)\n".write(to: Paths.pidFile, atomically: true, encoding: .utf8)
    }

    /// The live recorder, if any. Stale files (process gone) are removed.
    static func read() -> RunningRecorder? {
        guard let text = try? String(contentsOf: Paths.pidFile, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let pid = pid_t(lines[0]) else { return nil }
        guard isAlive(pid) else {
            try? FileManager.default.removeItem(at: Paths.pidFile)
            return nil
        }
        return RunningRecorder(pid: pid, dir: lines[1])
    }

    static func remove() {
        if let text = try? String(contentsOf: Paths.pidFile, encoding: .utf8), text.hasPrefix("\(getpid())\n") {
            try? FileManager.default.removeItem(at: Paths.pidFile)
        }
    }
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("\(Style.bad) \(message)\n", stderr)
    exit(code)
}

enum Launcher {
    /// `rec start [--out DIR] [--mic NAME|UID] [--yes] [--detach] [--dictate]`
    static func start(_ args: [String]) -> Never {
        var outDir: String?
        var detach = false
        var dictate = false
        var skipPicker = false
        var micQuery: String?
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "-o", "--out":
                guard let value = it.next() else { fail("--out needs a directory", code: 64) }
                outDir = value
            case "-m", "--mic":
                guard let value = it.next() else { fail("--mic needs a device name or UID", code: 64) }
                micQuery = value
            case "-y", "--yes": skipPicker = true
            case "-d", "--detach": detach = true
            case "--dictate": dictate = true
            default: fail("unknown option \(arg)", code: 64)
            }
        }
        if let running = PIDFile.read() {
            fail("already recording to \(Style.path(running.dir)) (pid \(running.pid)); run `rec stop` first")
        }

        // Choose the mic once, now; the recorder stays pinned to its UID.
        let interactive = !skipPicker && isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        let micUID: String
        if let micQuery {
            let resolved = AudioDevices.resolveInput(micQuery)
            guard let input = resolved.input else { fail(resolved.error ?? "unknown mic") }
            micUID = input.uid
        } else {
            micUID = chooseMic(interactive: interactive, dictate: dictate).uid
        }
        checkTranscription(interactive: interactive)

        let dir: URL
        if let outDir {
            dir = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath)
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            dir = Paths.recordingsRoot.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(dir.path): \(error.localizedDescription)")
        }

        guard let app = appBundle() else {
            // Development build outside Rec.app: TCC will attribute capture to the terminal.
            fputs("\(Style.warn) not running from Rec.app; recording in-process (permissions belong to your terminal)\n", stderr)
            Recorder(dir: dir, micUID: micUID, dictation: dictate).run()
        }

        // Launch through LaunchServices so Rec.app is its own "responsible process"
        // for TCC; exec'ing it directly would attribute mic/system-audio access to
        // the terminal. Output goes to this terminal, or a log file when detached.
        let tty = [STDOUT_FILENO, STDERR_FILENO].lazy.compactMap { ttyname($0) }.first.map { String(cString: $0) }
        let output = (detach ? nil : tty) ?? dir.appendingPathComponent("rec.log").path
        if !FileManager.default.fileExists(atPath: output) {
            FileManager.default.createFile(atPath: output, contents: nil)
        }
        // LaunchServices doesn't pass our environment along; forward colour preferences.
        let env = ProcessInfo.processInfo.environment
        let forwarded = ["NO_COLOR", "COLORTERM", "TERM"].flatMap { key in env[key].map { ["--env", "\(key)=\($0)"] } ?? [] }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-g"] + forwarded
            + ["--stdout", output, "--stderr", output, app.path, "--args", "_record", dir.path, micUID]
            + (dictate ? ["--dictate"] : [])
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            fail("could not launch \(app.path): \(error.localizedDescription)")
        }
        guard open.terminationStatus == 0 else { fail("open exited with \(open.terminationStatus)") }

        guard let recorder = waitForRecorder(dir: dir, timeout: 10) else {
            fail("recorder did not start; see \(Style.path(output))")
        }
        if detach {
            print("\(Style.strong("●", Style.accent)) \(Style.bold("recording")) in the background  \(Style.dim("pid \(recorder.pid)"))")
            print("  \(Style.dim("session"))  \(Style.path(dir.path))")
            print("  \(Style.dim("log    "))  \(Style.path(output))")
            print("  \(Style.dim("stop   "))  rec stop")
            exit(0)
        }

        // Stay in the foreground until the recorder exits; Ctrl-C asks it to stop cleanly.
        // Don't echo "^C" over the recorder's meter line, and put the terminal back
        // before transcribing here. `rec stop` leaves the transcription to this terminal.
        var savedTerm = termios()
        let haveTerm = isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &savedTerm) == 0
        if haveTerm {
            var quiet = savedTerm
            quiet.c_lflag &= ~tcflag_t(ECHOCTL | ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
        }
        try? "\(getpid())\n".write(to: dir.appendingPathComponent(".attached.pid"), atomically: true, encoding: .utf8)
        func finish() -> Never {
            if haveTerm { tcsetattr(STDIN_FILENO, TCSANOW, &savedTerm) }
            if Style.enabled { fputs("\u{1B}[?25h", stdout); fflush(stdout) }
            Transcriber.runAttached(dir: dir.path)
        }

        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { kill(recorder.pid, SIGTERM) }
            source.resume()
            sources.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler {
            guard !isAlive(recorder.pid) else { return }
            withExtendedLifetime(sources) { finish() }
        }
        timer.resume()
        dispatchMain()
    }

    static func stop() -> Never {
        guard let recorder = PIDFile.read() else { fail("not recording") }
        kill(recorder.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(15)
        while isAlive(recorder.pid), Date() < deadline { usleep(100_000) }
        if isAlive(recorder.pid) { fail("recorder (pid \(recorder.pid)) did not exit within 15s") }
        let sessionURL = URL(fileURLWithPath: recorder.dir).appendingPathComponent("session.json")
        let stopped = "\(Style.strong("■", Style.accent)) \(Style.bold("stopped"))"
        if let data = try? Data(contentsOf: sessionURL),
           let session = try? JSONDecoder().decode(SessionInfo.self, from: data),
           let duration = session.durationSeconds {
            print("\(stopped)  \(clock(duration)) recorded")
        } else {
            print(stopped)
        }
        print("  \(Style.dim("session"))  \(Style.path(recorder.dir))")
        if let owner = attachedLauncher(dir: recorder.dir) {
            print("  \(Style.dim("transcript"))  in the terminal running `rec start` \(Style.faint("pid \(owner)"))")
        } else {
            Transcriber.launchInBackground(dir: recorder.dir)
        }
        exit(0)
    }

    /// The foreground `rec start` for this session, which transcribes it in its own terminal.
    private static func attachedLauncher(dir: String) -> pid_t? {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".attached.pid")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), isAlive(pid) else { return nil }
        return pid
    }

    /// `rec open`: shows the recordings folder in Finder.
    static func openRecordings() -> Never {
        let dir = Paths.recordingsRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [dir.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            fail("could not run open: \(error.localizedDescription)")
        }
        guard open.terminationStatus == 0 else { fail("open exited with \(open.terminationStatus)") }
        exit(0)
    }

    static func devices() -> Never {
        let builtIn = AudioDevices.builtInInputUID()
        let systemDefault = AudioDevices.defaultInputUID()
        let lidClosed = isLidClosed() == true
        let inputs = AudioDevices.inputs()
        let recDefault = defaultMic(inputs).map { inputs[$0].uid }
        let nameWidth = inputs.map(\.name.count).max() ?? 0
        let kindWidth = inputs.map(\.kind.count).max() ?? 0
        guard !inputs.isEmpty else { print(Style.dim("no input devices connected")); exit(0) }
        for input in inputs {
            let isDefault = input.uid == recDefault
            let mark = isDefault ? Style.strong("❯", Style.accent) : " "
            let name = Style.pad(isDefault ? Style.bold(input.name) : input.name, nameWidth)
            var tags: [String] = []
            if isDefault { tags.append(Style.fg("rec default", Style.accent)) }
            if input.uid == systemDefault { tags.append(Style.fg("system default", Style.blue)) }
            if input.uid == builtIn, lidClosed { tags.append(Style.fg("lid closed, muted", Style.yellow)) }
            print("\(mark) \(name)  \(Style.dim(Style.pad(input.kind, kindWidth)))  \(tags.joined(separator: Style.faint(" · ")))")
            print("  \(Style.faint(input.uid))")
        }
        exit(0)
    }

    /// REC_MIC if it's connected; otherwise the built-in mic, unless the lid is
    /// closed (which mutes it), in which case the best external mic.
    private static func defaultMic(_ inputs: [AudioDevices.Input]) -> Int? {
        if let pref = ProcessInfo.processInfo.environment["REC_MIC"], !pref.isEmpty,
           let match = AudioDevices.resolveInput(pref).input,
           let i = inputs.firstIndex(where: { $0.uid == match.uid }) {
            return i
        }
        let lidClosed = isLidClosed() == true
        func rank(_ input: AudioDevices.Input) -> Int {
            switch input.kind {
            case "built-in": lidClosed ? 8 : 0
            case "USB": 1
            case "Bluetooth": 2
            case "iPhone": 5
            case "virtual": 9
            default: 3
            }
        }
        return inputs.indices.min { (rank(inputs[$0]), $0) < (rank(inputs[$1]), $1) }
    }

    private static func chooseMic(interactive: Bool, dictate: Bool) -> AudioDevices.Input {
        let inputs = AudioDevices.inputs()
        guard let defaultIndex = defaultMic(inputs) else { fail("no input devices connected") }
        let builtIn = AudioDevices.builtInInputUID()
        let lidClosed = isLidClosed() == true
        func mutedBuiltIn(_ input: AudioDevices.Input) -> Bool { lidClosed && input.uid == builtIn }

        guard interactive, let term = RawTerminal() else {
            let input = inputs[defaultIndex]
            print("\(Style.ok) \(Style.dim("mic")) \(Style.bold(input.name))")
            if mutedBuiltIn(input) { fputs("\(Style.warn) the lid is closed, so the built-in mic will record silence\n", stderr) }
            return input
        }
        return pickMic(inputs, defaultIndex: defaultIndex, muted: mutedBuiltIn, dictate: dictate, term: term)
    }

    /// Arrow-key list: ↑/↓ (or j/k, Tab) to move, 1–9 to jump, Enter to choose,
    /// Esc/q/Ctrl-C to cancel. Collapses to a one-line summary once chosen.
    private static func pickMic(_ inputs: [AudioDevices.Input], defaultIndex: Int,
                                muted: (AudioDevices.Input) -> Bool, dictate: Bool, term: RawTerminal) -> AudioDevices.Input {
        var cursor = defaultIndex
        var confirming = false
        var drawnLines = 0
        let nameWidth = inputs.map(\.name.count).max() ?? 0

        func rewind() -> String {
            (drawnLines > 1 ? "\u{1B}[\(drawnLines - 1)A" : "") + "\r\u{1B}[J"
        }
        func draw() {
            var lines = [Style.bold("Which mic?") + "  " + Style.dim(dictate ? "rec records only this, for dictation" : "rec records this plus all system audio")]
            for (i, input) in inputs.enumerated() {
                let selected = i == cursor
                let pointer = selected ? Style.strong("❯", Style.accent) : " "
                let name = Style.pad(selected ? Style.strong(input.name, Style.accent) : input.name, nameWidth)
                var notes = [Style.dim(input.kind)]
                if i == defaultIndex { notes.append(Style.dim("default")) }
                if muted(input) { notes.append(Style.fg("lid closed, muted", Style.yellow)) }
                lines.append("\(pointer) \(name)  \(notes.joined(separator: Style.faint(" · ")))")
            }
            if confirming {
                lines.append("\(Style.warn) The lid is closed, so this mic will record silence. Use it anyway? \(Style.dim("y/N"))")
            } else if inputs.count > 1 {
                lines.append(Style.faint("↑↓ move · enter choose · 1–\(min(inputs.count, 9)) jump · esc cancel"))
            } else {
                lines.append(Style.faint("enter choose · esc cancel"))
            }
            term.write(rewind() + lines.joined(separator: "\n"))
            drawnLines = lines.count
        }
        func done(_ summary: String) {
            term.write(rewind())
            term.restore()
            print(summary)
        }

        draw()
        while true {
            let key = term.readKey()
            if confirming {
                confirming = false
                if case .char(let c) = key, c == "y" || c == "Y" {
                    done("\(Style.warn) \(Style.dim("mic")) \(Style.bold(inputs[cursor].name))  \(Style.fg("lid closed", Style.yellow))")
                    return inputs[cursor]
                }
                draw()
                continue
            }
            switch key {
            case .up, .char("k"): cursor = (cursor - 1 + inputs.count) % inputs.count
            case .down, .char("j"), .char("\t"): cursor = (cursor + 1) % inputs.count
            case .char(let c) where c.wholeNumberValue.map { (1...inputs.count).contains($0) } == true:
                cursor = c.wholeNumberValue! - 1
            case .enter:
                if muted(inputs[cursor]) {
                    confirming = true
                } else {
                    done("\(Style.ok) \(Style.dim("mic")) \(Style.bold(inputs[cursor].name))")
                    return inputs[cursor]
                }
            case .cancel, .char("q"):
                done("\(Style.dim("○ cancelled"))")
                exit(130)
            default: break
            }
            draw()
        }
    }

    /// Transcripts need a vault: ask for one on first use, and make sure its
    /// transcriptions/ folder is still there. Recording goes ahead either way.
    private static func checkTranscription(interactive: Bool) {
        guard let config = Config.load() else {
            if interactive {
                _ = ConfigCommand.firstRun()
            } else {
                print("\(Style.warn) no Obsidian vault configured, so this recording won't be transcribed (see `rec config`)")
            }
            return
        }
        if let problem = Vault.check(config.vault) {
            fputs("\(Style.warn) \(problem); transcription will fail until you run `rec config`\n", stderr)
        } else if (try? Vault.ensureTranscriptionsDir(config)) == nil {
            fputs("\(Style.warn) cannot create \(Style.path(config.transcriptionsDir.path))\n", stderr)
        }
    }

    static func status() -> Never {
        guard let recorder = PIDFile.read() else { print(Style.dim("○ not recording")); exit(1) }
        let sessionURL = URL(fileURLWithPath: recorder.dir).appendingPathComponent("session.json")
        let session = (try? Data(contentsOf: sessionURL)).flatMap { try? JSONDecoder().decode(SessionInfo.self, from: $0) }
        let elapsed = session.map { "  " + clock(Date().timeIntervalSince1970 - Double($0.startEpochMs) / 1000) } ?? ""
        print("\(Style.strong("●", Style.accent)) \(Style.bold("recording"))\(elapsed)  \(Style.dim("pid \(recorder.pid)"))")
        if let uid = session?.micDeviceUID {
            let name = AudioDevices.device(uid: uid).flatMap(AudioDevices.name) ?? uid
            print("  \(Style.dim("mic    "))  \(name)")
        }
        print("  \(Style.dim("session"))  \(Style.path(recorder.dir))")
        exit(0)
    }

    private static func waitForRecorder(dir: URL, timeout: TimeInterval) -> RunningRecorder? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = PIDFile.read(), r.dir == dir.path { return r }
            usleep(100_000)
        }
        return nil
    }

    /// The enclosing Rec.app, resolving symlinks (e.g. ~/.local/bin/rec).
    private static func appBundle() -> URL? {
        var size = UInt32(PATH_MAX)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        let exe = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}
