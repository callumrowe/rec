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
    fputs("rec: \(message)\n", stderr)
    exit(code)
}

enum Launcher {
    /// `rec start [--out DIR] [--mic NAME|UID] [--yes] [--detach]`
    static func start(_ args: [String]) -> Never {
        var outDir: String?
        var detach = false
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
            default: fail("unknown option \(arg)", code: 64)
            }
        }
        if let running = PIDFile.read() {
            fail("already recording to \(running.dir) (pid \(running.pid)); run `rec stop` first")
        }

        // Choose the mic once, now; the recorder stays pinned to its UID.
        let interactive = !skipPicker && isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        let micUID: String
        if let micQuery {
            let resolved = AudioDevices.resolveInput(micQuery)
            guard let input = resolved.input else { fail(resolved.error ?? "unknown mic") }
            micUID = input.uid
        } else {
            micUID = chooseMic(interactive: interactive).uid
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
            fputs("rec: not running from Rec.app; recording in-process (permissions belong to your terminal)\n", stderr)
            Recorder(dir: dir, micUID: micUID).run()
        }

        // Launch through LaunchServices so Rec.app is its own "responsible process"
        // for TCC; exec'ing it directly would attribute mic/system-audio access to
        // the terminal. Output goes to this terminal, or a log file when detached.
        let tty = [STDOUT_FILENO, STDERR_FILENO].lazy.compactMap { ttyname($0) }.first.map { String(cString: $0) }
        let output = (detach ? nil : tty) ?? dir.appendingPathComponent("rec.log").path
        if !FileManager.default.fileExists(atPath: output) {
            FileManager.default.createFile(atPath: output, contents: nil)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-g", "--stdout", output, "--stderr", output, app.path, "--args", "_record", dir.path, micUID]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            fail("could not launch \(app.path): \(error.localizedDescription)")
        }
        guard open.terminationStatus == 0 else { fail("open exited with \(open.terminationStatus)") }

        guard let recorder = waitForRecorder(dir: dir, timeout: 10) else {
            fail("recorder did not start; see \(output)")
        }
        if detach {
            print("rec: recording → \(dir.path) (pid \(recorder.pid)), log at \(output)")
            print("rec: stop with `rec stop`")
            exit(0)
        }

        // Stay in the foreground until the recorder exits; Ctrl-C asks it to stop cleanly.
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
            Transcriber.launchInBackground(dir: dir.path)
            withExtendedLifetime(sources) { exit(0) }
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
        if let data = try? Data(contentsOf: sessionURL),
           let session = try? JSONDecoder().decode(SessionInfo.self, from: data),
           let duration = session.durationSeconds {
            print("rec: stopped, \(clock(duration)) recorded → \(recorder.dir)")
        } else {
            print("rec: stopped → \(recorder.dir)")
        }
        Transcriber.launchInBackground(dir: recorder.dir)
        exit(0)
    }

    static func devices() -> Never {
        let builtIn = AudioDevices.builtInInputUID()
        let systemDefault = AudioDevices.defaultInputUID()
        let lidClosed = isLidClosed() == true
        let inputs = AudioDevices.inputs()
        let recDefault = defaultMic(inputs).map { inputs[$0].uid }
        let width = inputs.map(\.name.count).max() ?? 0
        for input in inputs {
            var tags = [input.kind]
            if input.uid == builtIn, lidClosed { tags.append("lid closed, muted") }
            if input.uid == recDefault { tags.append("rec default") }
            if input.uid == systemDefault { tags.append("system default") }
            let name = input.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(name)  \(input.uid)  (\(tags.joined(separator: ", ")))")
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

    private static func chooseMic(interactive: Bool) -> AudioDevices.Input {
        let inputs = AudioDevices.inputs()
        guard let defaultIndex = defaultMic(inputs) else { fail("no input devices connected") }
        let builtIn = AudioDevices.builtInInputUID()
        let lidClosed = isLidClosed() == true
        func mutedBuiltIn(_ input: AudioDevices.Input) -> Bool { lidClosed && input.uid == builtIn }

        guard interactive else {
            let input = inputs[defaultIndex]
            print("rec: mic: \(input.name)")
            if mutedBuiltIn(input) { fputs("rec: ⚠ the lid is closed, so the built-in mic will record silence\n", stderr) }
            return input
        }

        print("Mic for this recording:")
        let width = inputs.map(\.name.count).max() ?? 0
        for (i, input) in inputs.enumerated() {
            var notes = [input.kind]
            if mutedBuiltIn(input) { notes.append("lid closed, muted") }
            let name = input.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("  \(i == defaultIndex ? "›" : " ") \(i + 1)) \(name)  \(notes.joined(separator: " · "))")
        }
        while true {
            print("Choose [\(defaultIndex + 1)]: ", terminator: "")
            fflush(stdout)
            guard let line = readLine() else { return inputs[defaultIndex] }
            let text = line.trimmingCharacters(in: .whitespaces)
            let index: Int
            if text.isEmpty {
                index = defaultIndex
            } else if let n = Int(text), inputs.indices.contains(n - 1) {
                index = n - 1
            } else {
                print("Enter 1–\(inputs.count), or press Enter for \(defaultIndex + 1).")
                continue
            }
            let input = inputs[index]
            if mutedBuiltIn(input) {
                print("The lid is closed, so the built-in mic will record silence. Use it anyway? [y/N]: ", terminator: "")
                fflush(stdout)
                guard readLine()?.lowercased().hasPrefix("y") == true else { continue }
            }
            return input
        }
    }

    /// Transcripts need a vault: ask for one on first use, and make sure its
    /// transcriptions/ folder is still there. Recording goes ahead either way.
    private static func checkTranscription(interactive: Bool) {
        guard let config = Config.load() else {
            if interactive {
                _ = ConfigCommand.firstRun()
            } else {
                print("rec: no Obsidian vault configured, so this recording won't be transcribed (see `rec config`)")
            }
            return
        }
        if let problem = Vault.check(config.vault) {
            fputs("rec: ⚠ \(problem); transcription will fail until you run `rec config`\n", stderr)
        } else if (try? Vault.ensureTranscriptionsDir(config)) == nil {
            fputs("rec: ⚠ cannot create \(config.transcriptionsDir.path)\n", stderr)
        }
    }

    static func status() -> Never {
        guard let recorder = PIDFile.read() else { print("rec: not recording"); exit(1) }
        print("rec: recording → \(recorder.dir) (pid \(recorder.pid))")
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
