import AVFoundation
import CoreAudio
import Foundation

struct SessionInfo: Codable {
    struct Event: Codable {
        let t: Double
        let message: String
    }

    var version = 1
    var start: String
    var startEpochMs: Int64
    var sampleRate = Int(TrackWriter.sampleRate)
    var files = ["mic": "mic.wav", "system": "system.wav"]
    var micDeviceUID: String
    var systemClockDeviceUID: String?
    var end: String?
    var durationSeconds: Double?
    var frames: Int64?
    var capturedFrames: [String: Int64]?
    var events: [Event] = []
}

let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// The long-running recording process (`rec _record <dir>`), launched inside Rec.app.
final class Recorder {
    private let dir: URL
    private let interactive = isatty(STDOUT_FILENO) != 0
    private var t0: UInt64 = 0
    private var session: SessionInfo!
    private let eventsLock = NSLock()
    private var meterLineVisible = false

    private var micWriter: TrackWriter!
    private var systemWriter: TrackWriter!
    private var mic: MicCapture!
    private var system: SystemTap!
    private var lastSystemRestart = Date.distantPast

    private var silentSince: [String: Date] = [:]
    private var silenceWarned: Set<String> = []
    private var ticks = 0
    private var lastLidClosed: Bool?
    private var stopping = false
    private var keepAlive: [AnyObject] = []

    static let silenceThreshold = 1e-4  // -80 dBFS; real mics idle around -60..-70
    static let silenceWarnAfter: TimeInterval = 10

    init(dir: URL) {
        self.dir = dir
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IOLBF, 0)
        PIDFile.write(dir: dir)
        say("rec: session \(dir.path)")

        if !requestMicrophoneAccess() {
            say("⚠ microphone access denied: mic.wav will be silent. Allow Rec in System Settings › Privacy & Security › Microphone.")
        }
        let micUID = AudioDevices.builtInInputUID() ?? "BuiltInMicrophoneDevice"

        // Both tracks are positioned relative to this single instant.
        t0 = mach_absolute_time()
        let startDate = Date()
        session = SessionInfo(start: iso8601.string(from: startDate),
                              startEpochMs: Int64((startDate.timeIntervalSince1970 * 1000).rounded()),
                              micDeviceUID: micUID)
        do {
            micWriter = try TrackWriter(name: "mic", url: dir.appendingPathComponent("mic.wav"), t0: t0, log: log)
            systemWriter = try TrackWriter(name: "system", url: dir.appendingPathComponent("system.wav"), t0: t0, log: log)
        } catch {
            say("✖ cannot create output files: \(error.localizedDescription)")
            PIDFile.remove()
            exit(1)
        }

        system = SystemTap(writer: systemWriter)
        startSystem()
        mic = MicCapture(uid: micUID, writer: micWriter, log: log)
        mic.start()
        saveSession()
        say("rec: recording (mic: \(micUID)). Stop with `rec stop` or Ctrl-C.")

        let meterTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(meterTimer, forMode: .common)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            keepAlive.append(source)
        }
        RunLoop.main.run()
        exit(0)
    }

    private func startSystem() {
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
        let micMeter = micWriter.takeMeter()
        let systemMeter = systemWriter.takeMeter()

        if ticks % 2 == 0 {
            mic.poll()
            // An aggregate device runs continuously (zeros when nothing plays), so
            // no buffers at all means the tap broke, not that the call went quiet.
            if (!system.isRunning || systemMeter.secondsSinceLastBuffer > 3),
               Date().timeIntervalSince(lastSystemRestart) > 5 {
                if system.isRunning { log("system: no audio buffers for 3s, rebuilding tap") }
                system.stop()
                startSystem()
            }
        }
        if ticks % 4 == 0 {
            micWriter.flushHeader()
            systemWriter.flushHeader()
            saveSession()
        }

        let lidClosed = isLidClosed() == true
        if lidClosed != lastLidClosed {
            if lidClosed { log("mic: MacBook lid is closed; the built-in mic is muted until it opens") }
            else if lastLidClosed != nil { log("mic: MacBook lid opened") }
            lastLidClosed = lidClosed
        }
        checkSilence("mic", micMeter,
                     hint: lidClosed ? "the MacBook lid is closed, which mutes the built-in mic"
                         : "check Rec has Microphone permission (System Settings › Privacy & Security › Microphone) and the mic isn't muted")
        checkSilence("system", systemMeter,
                     hint: "if audio is playing, Rec is missing System Audio Recording permission (System Settings › Privacy & Security › Screen & System Audio Recording)")

        let elapsed = hostSeconds(from: t0, to: mach_absolute_time())
        let line = "● \(clock(elapsed))   mic \(meterText(micMeter, "mic"))   sys \(meterText(systemMeter, "system"))"
        if interactive {
            eventsLock.withLock {
                writeOut("\r\u{1B}[2K\(line)")
                meterLineVisible = true
            }
        } else if ticks % 10 == 0 {
            say(line)
        }
    }

    private func meterText(_ meter: TrackWriter.Meter, _ track: String) -> String {
        guard let rms = meter.rms else { return "  -- no input --          " }
        let db = rms > 0 ? 20 * log10(rms) : -120
        let width = 12
        let filled = Int(((db + 70) / 70 * Double(width)).rounded()).clamped(0, width)
        let bar = String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
        let flag = silenceWarned.contains(track) ? " SILENT" : ""
        return String(format: "%@ %6.1f dB%@", bar, max(db, -99.9), flag)
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
        system.stop()
        let micResult = micWriter.finalize(frames: frames)
        let systemResult = systemWriter.finalize(frames: frames)

        eventsLock.withLock {
            session.end = iso8601.string(from: endDate)
            session.durationSeconds = (duration * 1000).rounded() / 1000
            session.frames = frames
            session.capturedFrames = ["mic": micResult.captured, "system": systemResult.captured]
        }
        saveSession()
        if interactive { print("") }
        say(String(format: "rec: stopped after %@ — mic.wav and system.wav are %lld frames (%.3fs) each",
                   clock(duration), frames, Double(frames) / TrackWriter.sampleRate))
        say("rec: \(dir.path)")
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
        say("[\(clock(t))] \(message)")
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
