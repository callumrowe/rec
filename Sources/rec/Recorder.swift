import AppKit
import AVFoundation
import CoreAudio
import Foundation

struct SessionInfo: Codable {
    struct Event: Codable {
        let t: Double
        let message: String
    }

    /// Where `rec import` got the audio from.
    struct Source: Codable {
        var path: String
        var memoID: String?
        var title: String?
    }

    var version = 1
    /// "dictation" for `rec start --dictate` (mic only), "import" for `rec import` (audio.wav only);
    /// absent for a meeting (mic + system audio).
    var mode: String?
    var start: String
    var startEpochMs: Int64
    var sampleRate = Int(TrackWriter.sampleRate)
    var files = ["mic": "mic.wav", "system": "system.wav"]
    var micDeviceUID: String?
    var micName: String?
    var systemClockDeviceUID: String?
    var end: String?
    var durationSeconds: Double?
    var frames: Int64?
    var capturedFrames: [String: Int64]?
    var events: [Event] = []
    var source: Source?
    /// An import's `--as dictation|conversation`; absent means decided by how many voices the diarizer hears.
    var importAs: String?

    var isDictation: Bool { mode == "dictation" }
    var isImport: Bool { mode == "import" }
}

let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// The long-running recording process (`rec _record <dir> [<mic uid>] [--dictate]`), launched inside Rec.app.
/// Dictation records the mic alone: no system tap, no test chime.
final class Recorder {
    private let dir: URL
    private let requestedMicUID: String?
    private let dictation: Bool
    private var micIsBuiltIn = true
    private let interactive = isatty(STDOUT_FILENO) != 0
    private var t0: UInt64 = 0
    private var session: SessionInfo!
    private let eventsLock = NSLock()
    private var meterLineVisible = false

    private var micWriter: TrackWriter!
    private var systemWriter: TrackWriter?
    private var mic: MicCapture!
    private var system: SystemTap?
    private var lastSystemRestart = Date.distantPast
    private var talk: TalkMonitor?
    private var indicator: TalkIndicator?

    private var silentSince: [String: Date] = [:]
    private var silenceWarned: Set<String> = []
    private var ticks = 0
    private var lastLidClosed: Bool?

    // Startup check: prove both capture paths work in the first few seconds.
    private var micName = ""
    private var micPeakRMS = 0.0
    private var micChecked = false
    private var chime: NSSound?
    private var chimePlayedAt: Date?
    private var systemConfirmed = false
    private var systemCheckFailed = false
    private var stopping = false
    private var keepAlive: [AnyObject] = []

    static let silenceThreshold = 1e-4  // -80 dBFS; real mics idle around -60..-70
    static let silenceWarnAfter: TimeInterval = 10

    init(dir: URL, micUID: String? = nil, dictation: Bool = false) {
        self.dir = dir
        self.requestedMicUID = micUID
        self.dictation = dictation
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IOLBF, 0)
        PIDFile.write(dir: dir)

        if !requestMicrophoneAccess() {
            say(Style.event("⚠ microphone access denied: mic.wav will be silent. Allow Rec in System Settings › Privacy & Security › Microphone."))
        }
        let builtInUID = AudioDevices.builtInInputUID() ?? "BuiltInMicrophoneDevice"
        let micUID = requestedMicUID ?? builtInUID
        micIsBuiltIn = micUID == builtInUID

        // Both tracks are positioned relative to this single instant.
        t0 = mach_absolute_time()
        let startDate = Date()
        session = SessionInfo(start: iso8601.string(from: startDate),
                              startEpochMs: Int64((startDate.timeIntervalSince1970 * 1000).rounded()),
                              micDeviceUID: micUID)
        if dictation {
            session.mode = "dictation"
            session.files = ["mic": "mic.wav"]
        }
        do {
            micWriter = try TrackWriter(name: "mic", url: dir.appendingPathComponent("mic.wav"), t0: t0, log: log)
            if !dictation {
                systemWriter = try TrackWriter(name: "system", url: dir.appendingPathComponent("system.wav"), t0: t0, log: log)
            }
        } catch {
            say(Style.event("✗ cannot create output files: \(error.localizedDescription)"))
            PIDFile.remove()
            exit(1)
        }

        micName = AudioDevices.device(uid: micUID).flatMap(AudioDevices.name) ?? micUID
        eventsLock.withLock { session.micName = micName }
        say("")
        say("\(Style.strong("●", Style.accent)) \(Style.strong("REC", Style.accent))  \(Style.dim(dictation ? "dictation, mic only" : "mic + system audio"))")
        say("  \(Style.dim("mic    "))  \(micName)  \(Style.faint(micUID))")
        say("  \(Style.dim("session"))  \(Style.path(dir.path))")
        say("  \(Style.dim("stop   "))  " + (interactive ? "ctrl-c" + Style.dim(" or ") : "") + "rec stop")
        say("")
        if interactive, Style.enabled { writeOut("\u{1B}[?25l") }

        // Meetings only: the menu bar dot for how long you've been talking.
        let talkSettings = Config.load()?.talk ?? TalkSettings()
        if let systemWriter, talkSettings.isEnabled {
            let talk = TalkMonitor(settings: talkSettings, system: true, log: log)
            micWriter.listener = { talk.feed(.mic, $0, count: $1) }
            systemWriter.listener = { talk.feed(.system, $0, count: $1) }
            talk.start()
            self.talk = talk
            NSApplication.shared.setActivationPolicy(.accessory)
            indicator = TalkIndicator(settings: talkSettings)
        }

        if let systemWriter {
            system = SystemTap(writer: systemWriter)
            startSystem()
        }
        mic = MicCapture(uid: micUID, writer: micWriter, log: log)
        mic.start()
        saveSession()

        let meterTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(meterTimer, forMode: .common)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            keepAlive.append(source)
        }
        NSApplication.shared.run()
        exit(0)
    }

    private func startSystem() {
        guard let system else { return }
        lastSystemRestart = Date()
        do {
            try system.start()
            let uid = system.clockDeviceUID
            eventsLock.withLock { session?.systemClockDeviceUID = uid }
        } catch {
            log("system: tap failed to start: \(error); retrying")
        }
    }

    private func requestMicrophoneAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0; done.signal() }
            done.wait()
            return granted
        default: return false
        }
    }

    // MARK: - Periodic work

    private func tick() {
        guard !stopping else { return }
        ticks += 1
        if let talk, let indicator {
            let state = talk.state
            if state == .unavailable {
                indicator.remove()
                self.indicator = nil
            } else {
                indicator.update(state)
            }
        }
        let micMeter = micWriter.takeMeter()
        let systemMeter = systemWriter?.takeMeter()

        if ticks % 2 == 0 {
            mic.poll()
            // An aggregate device runs continuously (zeros when nothing plays), so
            // no buffers at all means the tap broke, not that the call went quiet.
            if let system, let systemMeter, (!system.isRunning || systemMeter.secondsSinceLastBuffer > 3),
               Date().timeIntervalSince(lastSystemRestart) > 5 {
                if system.isRunning { log("system: no audio buffers for 3s, rebuilding tap") }
                system.stop()
                startSystem()
            }
        }
        if ticks % 4 == 0 {
            micWriter.flushHeader()
            systemWriter?.flushHeader()
            saveSession()
        }

        let lidClosed = micIsBuiltIn && isLidClosed() == true
        if lidClosed != lastLidClosed {
            if lidClosed { log("mic: MacBook lid is closed; the built-in mic is muted until it opens") }
            else if lastLidClosed != nil { log("mic: MacBook lid opened") }
            lastLidClosed = lidClosed
        }
        let micHint = lidClosed ? "the MacBook lid is closed, which mutes the built-in mic"
            : "check Rec has Microphone permission (System Settings › Privacy & Security › Microphone) and the mic isn't muted"
        let elapsed = hostSeconds(from: t0, to: mach_absolute_time())
        checkMic(micMeter, elapsed: elapsed, hint: micHint)
        checkSilence("mic", micMeter, hint: micHint)
        if let systemMeter {
            checkSystem(systemMeter)
            checkSilence("system", systemMeter,
                         hint: systemConfirmed ? "nothing is playing (capture was confirmed earlier, so the call may just be quiet)"
                             : "if audio is playing, Rec is missing System Audio Recording permission (System Settings › Privacy & Security › Screen & System Audio Recording)")
        }

        let barWidth = systemMeter == nil ? (terminalColumns() - 32).clamped(6, 48) : ((terminalColumns() - 46) / 2).clamped(6, 24)
        let dot = ticks % 2 == 0 ? Style.strong("●", Style.accent) : Style.faint("●")
        var line = "\(dot) \(Style.bold(clock(elapsed)))   \(Style.dim("mic")) \(meterText(micMeter, "mic", barWidth))"
        if let systemMeter { line += "   \(Style.dim("sys")) \(meterText(systemMeter, "system", barWidth))" }
        if interactive {
            eventsLock.withLock {
                writeOut("\r\u{1B}[2K\(line)")
                meterLineVisible = true
            }
        } else if ticks % 10 == 0 {
            say(line)
        }
    }

    /// Startup check for the mic: after 4s, is the device delivering anything above
    /// digital silence? (A live mic's noise floor is well above the threshold, so no need to speak.)
    private func checkMic(_ mic: TrackWriter.Meter, elapsed: Double, hint: String) {
        guard !micChecked else { return }
        micPeakRMS = max(micPeakRMS, mic.rms ?? 0)
        guard elapsed >= 4 else { return }
        micChecked = true
        if micPeakRMS >= Self.silenceThreshold {
            log(String(format: "✓ mic: %@ is live (%.0f dB)", micName, 20 * log10(micPeakRMS)))
        } else if mic.secondsSinceLastBuffer.isInfinite {
            log("✗ mic: no audio arriving from \(micName): \(hint)")
        } else {
            log("✗ mic: \(micName) is sending pure silence: \(hint)")
        }
    }

    /// Startup check for system audio: a tap without permission returns silence,
    /// indistinguishable from nothing playing, so play a short chime and check the tap captures it.
    private func checkSystem(_ systemMeter: TrackWriter.Meter) {
        guard let system else { return }
        if !systemConfirmed, (systemMeter.rms ?? 0) >= Self.silenceThreshold {
            systemConfirmed = true
            log(chimePlayedAt == nil ? "✓ system audio: capturing" : "✓ system audio: capture confirmed (heard test chime)")
        }
        if !systemConfirmed, chimePlayedAt == nil, system.isRunning, systemMeter.secondsSinceLastBuffer < 1 {
            chime = NSSound(named: "Tink")
            chime?.volume = 0.3
            chime?.play()
            chimePlayedAt = Date()
        }
        if let chimePlayedAt, !systemConfirmed, !systemCheckFailed, Date().timeIntervalSince(chimePlayedAt) > 3 {
            systemCheckFailed = true
            log("✗ system audio: test chime was not captured. Rec is probably missing System Audio Recording permission "
                + "(System Settings › Privacy & Security › Screen & System Audio Recording). Stop, fix it, and start again.")
        }
    }

    private func meterText(_ meter: TrackWriter.Meter, _ track: String, _ width: Int) -> String {
        guard let rms = meter.rms else {
            return Style.pad(Style.fg("no input", Style.red), width) + "        "
        }
        let db = rms > 0 ? 20 * log10(rms) : -120
        let reading = String(format: "%4.0f dB", max(db, -99))
        let text = silenceWarned.contains(track) ? Style.strong("silent", Style.red) + "  " : Style.dim(reading)
        return Style.meter(db: db, width: width) + " " + text
    }

    private func terminalColumns() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }

    private func checkSilence(_ track: String, _ meter: TrackWriter.Meter, hint: String) {
        let silent = (meter.rms ?? 0) < Self.silenceThreshold
        if !silent {
            silentSince[track] = nil
            if silenceWarned.remove(track) != nil { log("\(track): signal is back") }
            return
        }
        let since = silentSince[track] ?? Date()
        silentSince[track] = since
        if Date().timeIntervalSince(since) >= Self.silenceWarnAfter, !silenceWarned.contains(track) {
            silenceWarned.insert(track)
            log("⚠ \(track) has been silent for \(Int(Self.silenceWarnAfter))s: \(hint)")
        }
    }

    // MARK: - Stop

    private func stop() {
        guard !stopping else { return }
        stopping = true
        let tEnd = mach_absolute_time()
        let endDate = Date()
        let duration = hostSeconds(from: t0, to: tEnd)
        let frames = Int64((duration * TrackWriter.sampleRate).rounded())

        mic.stop()
        system?.stop()
        let micResult = micWriter.finalize(frames: frames)
        let systemResult = systemWriter?.finalize(frames: frames)
        indicator?.remove()
        var talkFile: TalkFile?
        if let file = talk?.finish(timeout: 3) {
            do {
                try file.write(to: dir)
                talkFile = file
            } catch {
                log("talk: cannot write talk.json: \(error.localizedDescription)")
            }
        }

        eventsLock.withLock {
            session.end = iso8601.string(from: endDate)
            session.durationSeconds = (duration * 1000).rounded() / 1000
            session.frames = frames
            session.capturedFrames = ["mic": micResult.captured]
            if let systemResult { session.capturedFrames?["system"] = systemResult.captured }
        }
        saveSession()
        say("")
        say("\(Style.strong("■", Style.accent)) \(Style.bold("stopped"))  \(clock(duration)) recorded")
        let files = (systemWriter == nil ? ["mic.wav"] : ["mic.wav", "system.wav"]) + ["session.json"] + (talkFile == nil ? [] : ["talk.json"])
        say("  \(Style.dim("files  "))  \(files.joined(separator: " \(Style.faint("·")) "))  "
            + Style.dim(String(format: "%lld frames%@ (%.3fs)", frames, systemWriter == nil ? "" : " each", Double(frames) / TrackWriter.sampleRate)))
        if let talkFile { say("  \(Style.dim("talk   "))  \(talkFile.summary)") }
        say("  \(Style.dim("session"))  \(Style.path(dir.path))")
        if interactive, Style.enabled { writeOut("\u{1B}[?25h") }
        PIDFile.remove()
        exit(0)
    }

    // MARK: - Output

    /// Session events: printed and stored in session.json. Callable from any thread.
    private func log(_ message: String) {
        let t = hostSeconds(from: t0, to: mach_absolute_time())
        eventsLock.withLock {
            session?.events.append(.init(t: (t * 1000).rounded() / 1000, message: message))
        }
        say("\(Style.faint(clock(t)))  \(Style.event(message))")
    }

    private func say(_ message: String) {
        eventsLock.withLock {
            let prefix = meterLineVisible ? "\r\u{1B}[2K" : ""
            meterLineVisible = false
            writeOut(prefix + message + "\n")
        }
    }

    private func saveSession() {
        let data: Data? = eventsLock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try? encoder.encode(session)
        }
        guard let data else { return }
        try? data.write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }
}

/// Never throws or traps: stdout may be a terminal that has since been closed.
private func writeOut(_ s: String) {
    fputs(s, stdout)
    fflush(stdout)
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
