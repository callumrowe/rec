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
    /// `rec start [--out DIR] [--detach]`
    static func start(_ args: [String]) -> Never {
        var outDir: String?
        var detach = false
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "-o", "--out":
                guard let value = it.next() else { fail("--out needs a directory", code: 64) }
                outDir = value
            case "-d", "--detach": detach = true
            default: fail("unknown option \(arg)", code: 64)
            }
        }
        if let running = PIDFile.read() {
            fail("already recording to \(running.dir) (pid \(running.pid)); run `rec stop` first")
        }

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
            Recorder(dir: dir).run()
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
        open.arguments = ["-n", "-g", "--stdout", output, "--stderr", output, app.path, "--args", "_record", dir.path]
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
            if !isAlive(recorder.pid) { withExtendedLifetime(sources) { exit(0) } }
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
        exit(0)
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
