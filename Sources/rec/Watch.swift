import AppKit
import Foundation

/// `watch` in config.json. Every key is optional.
struct WatchSettings: Codable {
    /// Extra apps whose mic use means a call (bundle ID prefix or executable name).
    var apps: [String]?
    /// Apps whose mic use never means a call.
    var ignore: [String]?
    /// A call must hold the mic this long before recording starts.
    var startAfterSeconds: Double?
    /// The call app must let go of the mic this long before recording stops.
    var stopAfterSeconds: Double?
    /// Calls shorter than this are deleted instead of transcribed.
    var discardShorterThanSeconds: Double?
    /// false: no notification when an automatic recording starts.
    var notify: Bool?

    var startAfter: Double { startAfterSeconds ?? 4 }
    var stopAfter: Double { stopAfterSeconds ?? 15 }
    var minLength: Double { discardShorterThanSeconds ?? 60 }
    var notifies: Bool { notify ?? true }
}

/// `rec watch`: stays running (as a login item via `--install`) and records calls
/// automatically. A call is an app like Zoom, Teams or a browser holding the mic;
/// see CallDetector. Recording starts a few seconds into the call and stops once the
/// app lets go of the mic; calls under a minute (mic tests, wrong joins) are deleted.
/// While an automatic recording runs, a menu bar icon offers stop, discard and pause.
final class Watcher: NSObject {
    static let label = "com.callumrowe.rec.watch"
    static let pidFile = Paths.support.appendingPathComponent("watch.pid")
    static let plist = Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let logFile = Paths.home.appendingPathComponent("Library/Logs/rec-watch.log")

    private enum State {
        case idle
        /// A call is up; recording starts once it has lasted `startAfter`.
        case pending(app: String, since: Date)
        case recording(Recording)
        /// Stopped by hand (menu, `rec stop`) or someone else's recording is running:
        /// leave this call alone until it ends.
        case standingBy(lastCall: Date)
    }

    private struct Recording {
        let app: String
        let pid: pid_t
        let dir: URL
        let callStart: Date
        var lastCall: Date
    }

    private var state = State.idle
    private var pausedUntil: Date?
    private var statusItem: NSStatusItem?
    private var settings = WatchSettings()

    static func run(_ args: [String]) -> Never {
        switch args.first {
        case "--install": install()
        case "--uninstall": uninstall()
        case "--list": list()
        case nil: Watcher().loop()
        default: fail("unknown option \(args[0]); try rec watch [--install|--uninstall|--list]", code: 64)
        }
    }

    // MARK: - Loop

    private func loop() -> Never {
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IOLBF, 0)
        if let pid = Self.runningPID(), pid != getpid() {
            fail("already watching (pid \(pid)); `rec watch --uninstall` stops the login item")
        }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: Self.pidFile, atomically: true, encoding: .utf8)
        NSApplication.shared.setActivationPolicy(.accessory)
        say("watching for calls (pid \(getpid()))")

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            objc_setAssociatedObject(self, "sig\(sig)", source, .OBJC_ASSOCIATION_RETAIN)
        }
        tick()
        NSApplication.shared.run()
        exit(0)
    }

    /// Leaves a running recording alone: it carries on and `rec stop` still works.
    private func quit() {
        if case .recording(let r) = state { say("exiting; \(r.app) recording keeps going (rec stop to finish)") }
        if let text = try? String(contentsOf: Self.pidFile, encoding: .utf8), text.hasPrefix("\(getpid())\n") {
            try? FileManager.default.removeItem(at: Self.pidFile)
        }
        exit(0)
    }

    private func tick() {
        settings = Config.load()?.watch ?? WatchSettings()
        let now = Date()
        if let until = pausedUntil, now >= until {
            pausedUntil = nil
            say("auto-record resumed")
            updateMenu()
        }
        let running = PIDFile.read()
        var detector = CallDetector(extraApps: settings.apps ?? [], extraIgnored: settings.ignore ?? [])
        if let running { detector.ownPIDs.insert(running.pid) }
        let call = detector.detect(AudioProcesses.current())

        switch state {
        case .idle:
            guard let call, pausedUntil == nil else { return }
            if running != nil {
                say("\(call) call, but a recording is already running; leaving it alone")
                state = .standingBy(lastCall: now)
            } else {
                state = .pending(app: call, since: now)
                if settings.startAfter <= 0 { tick() }
            }

        case .pending(let app, let since):
            guard let call, pausedUntil == nil else { state = .idle; return }
            if running != nil { state = .standingBy(lastCall: now); return }
            if now.timeIntervalSince(since) >= settings.startAfter { start(app: call == app ? app : call, callStart: since) }

        case .recording(var r):
            guard isAlive(r.pid) else {
                say("\(r.app) recording was stopped outside the watcher")
                state = .standingBy(lastCall: call == nil ? .distantPast : now)
                updateMenu()
                return
            }
            if call != nil {
                r.lastCall = now
                state = .recording(r)
            } else if now.timeIntervalSince(r.lastCall) >= settings.stopAfter {
                finish(r, discard: r.lastCall.timeIntervalSince(r.callStart) < settings.minLength, reason: "call ended")
            }

        case .standingBy(let lastCall):
            if call != nil {
                state = .standingBy(lastCall: now)
            } else if now.timeIntervalSince(lastCall) >= settings.stopAfter {
                state = .idle
            }
        }
    }

    // MARK: - Start / stop

    private func start(app: String, callStart: Date) {
        say("\(app) call detected; starting to record")
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: Self.executablePath())
        p.arguments = ["start", "--detach", "--yes", "--trigger", app]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            say("could not run rec start: \(error.localizedDescription)")
        }
        guard p.terminationStatus == 0, let recorder = PIDFile.read() else {
            say("rec start failed (exit \(p.terminationStatus)); not retrying until this call ends")
            notify("Couldn't record \(app) call", "rec start failed; see \(Self.logFile.path)")
            state = .standingBy(lastCall: Date())
            return
        }
        state = .recording(Recording(app: app, pid: recorder.pid, dir: URL(fileURLWithPath: recorder.dir),
                                     callStart: callStart, lastCall: Date()))
        updateMenu()
        if settings.notifies {
            notify("Recording \(app)", "Stop or discard it from the rec icon in the menu bar.")
        }
    }

    /// Stops the recorder, then transcribes the session or deletes it.
    private func finish(_ r: Recording, discard: Bool, reason: String) {
        kill(r.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(15)
        while isAlive(r.pid), Date() < deadline { usleep(100_000) }
        if isAlive(r.pid) { say("recorder (pid \(r.pid)) did not exit within 15s") }
        if discard {
            if r.dir.path.hasPrefix(Paths.recordingsRoot.path + "/") {
                try? FileManager.default.removeItem(at: r.dir)
            }
            say("\(reason): \(r.app) recording discarded")
        } else {
            say("\(reason): \(r.app) recording stopped, transcribing \(r.dir.path)")
            Transcriber.launchInBackground(dir: r.dir.path)
        }
        state = reason == "call ended" ? .idle : .standingBy(lastCall: Date())
        updateMenu()
    }

    // MARK: - Menu bar

    private func updateMenu() {
        let recording: Recording? = if case .recording(let r) = state { r } else { nil }
        guard recording != nil || pausedUntil != nil else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let symbol = recording != nil ? "record.circle" : "pause.circle"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "rec")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        if let recording {
            menu.addItem(disabled("Recording \(recording.app) since \(time.string(from: recording.callStart))"))
            menu.addItem(action("Stop and transcribe", #selector(stopNow)))
            menu.addItem(action("Discard this recording", #selector(discardNow)))
            menu.addItem(.separator())
        }
        if let pausedUntil {
            menu.addItem(disabled("Auto-record paused until \(time.string(from: pausedUntil))"))
            menu.addItem(action("Resume auto-record", #selector(resume)))
        } else {
            menu.addItem(action("Pause auto-record for an hour", #selector(pause)))
        }
        item.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func stopNow() {
        guard case .recording(let r) = state else { return }
        finish(r, discard: false, reason: "stopped from the menu")
    }

    @objc private func discardNow() {
        guard case .recording(let r) = state else { return }
        finish(r, discard: true, reason: "discarded from the menu")
    }

    @objc private func pause() {
        pausedUntil = Date().addingTimeInterval(3600)
        say("auto-record paused for an hour")
        updateMenu()
    }

    @objc private func resume() {
        pausedUntil = nil
        say("auto-record resumed")
        updateMenu()
    }

    // MARK: - Output

    private func say(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("\(f.string(from: Date()))  \(message)")
    }

    static func notify(_ title: String, _ message: String) {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \(quoted(message)) with title \"rec\" subtitle \(quoted(title))"]
        try? p.run()
    }

    private func notify(_ title: String, _ message: String) { Self.notify(title, message) }

    // MARK: - Login item

    static func runningPID() -> pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), isAlive(pid) else { return nil }
        return pid
    }

    static func executablePath() -> String {
        var size = UInt32(PATH_MAX)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return CommandLine.arguments[0] }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }

    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static var domain: String { "gui/\(getuid())" }

    /// Writes a LaunchAgent that starts `rec watch` at login and restarts it if it dies.
    private static func install() -> Never {
        let exe = executablePath()
        guard exe.contains(".app/Contents/MacOS/") else {
            fail("run `make install` first: the login item must point at Rec.app, not \(exe)")
        }
        let plistBody: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "watch"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "EnvironmentVariables": ["NO_COLOR": "1"],
        ]
        do {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plistBody, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
        } catch {
            fail("cannot write \(plist.path): \(error.localizedDescription)")
        }
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        let status = launchctl(["bootstrap", domain, plist.path])
        guard status == 0 else { fail("launchctl bootstrap failed (\(status)); see \(plist.path)") }
        let deadline = Date().addingTimeInterval(5)
        while runningPID() == nil, Date() < deadline { usleep(100_000) }
        guard let pid = runningPID() else { fail("installed, but the watcher didn't start; see \(Style.path(logFile.path))") }
        print("\(Style.ok) \(Style.bold("watching for calls"))  \(Style.dim("pid \(pid), starts at login"))")
        print("  \(Style.dim("log "))  \(Style.path(logFile.path))")
        print("  \(Style.dim("off "))  rec watch --uninstall")
        exit(0)
    }

    private static func uninstall() -> Never {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plist)
        if let pid = runningPID() { kill(pid, SIGTERM) }
        print("\(Style.ok) stopped watching for calls")
        exit(0)
    }

    /// Restarts the login item so it runs a freshly installed Rec.app (used by `make install`).
    static func restartIfInstalled() {
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        _ = launchctl(["kickstart", "-k", "\(domain)/\(label)"])
    }

    /// `rec watch --list`: what's using audio now, and whether that counts as a call.
    private static func list() -> Never {
        let settings = Config.load()?.watch ?? WatchSettings()
        var detector = CallDetector(extraApps: settings.apps ?? [], extraIgnored: settings.ignore ?? [])
        if let running = PIDFile.read() { detector.ownPIDs.insert(running.pid) }
        let processes = AudioProcesses.current().filter { $0.input || $0.output }
        if processes.isEmpty { print(Style.dim("nothing is using audio")) }
        for p in processes {
            let io = [p.input ? "mic" : nil, p.output ? "speakers" : nil].compactMap { $0 }.joined(separator: " + ")
            let note = detector.isIgnored(p) ? Style.faint("  ignored") : ""
            print("  \(Style.bold(detector.displayName(p)))  \(Style.dim(io))  \(Style.faint(p.key))\(note)")
        }
        if let call = detector.detect(AudioProcesses.current()) {
            print("\(Style.strong("●", Style.accent)) \(Style.bold("call:")) \(call)")
        } else {
            print(Style.dim("○ no call"))
        }
        if let pid = runningPID() {
            print(Style.dim("watcher running (pid \(pid))"))
        } else {
            print(Style.dim("watcher not running; `rec watch --install` starts it at login"))
        }
        exit(0)
    }
}
