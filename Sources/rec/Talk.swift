import AppKit
import FluidAudio
import Foundation

/// `talk` in config.json: the menu bar "talking too long" dot and the talk stats
/// in the note. Every key is optional.
struct TalkSettings: Codable {
    /// false turns the dot and the stats off.
    var enabled: Bool?
    /// A turn of yours this long turns the dot amber, then red.
    var amberSeconds: Double?
    var redSeconds: Double?
    /// A pause shorter than this doesn't end your turn.
    var gapSeconds: Double?
    /// The other side talking this long does.
    var interruptSeconds: Double?
    /// Show the turn's elapsed seconds next to the dot.
    var showSeconds: Bool?

    var isEnabled: Bool { enabled ?? true }
    var amber: Double { amberSeconds ?? 60 }
    var red: Double { redSeconds ?? 90 }
    var gap: Double { gapSeconds ?? 2 }
    var interrupt: Double { interruptSeconds ?? 1 }
    var seconds: Bool { showSeconds ?? true }

    enum Level: String { case idle, green, amber, red }

    func level(_ state: TalkMonitor.State) -> Level {
        guard case .talking(let elapsed) = state else { return .idle }
        return elapsed >= red ? .red : elapsed >= amber ? .amber : .green
    }
}

/// Your speaking turns, one VAD chunk at a time. A turn starts when you speak and
/// ends at your last speech once you've been quiet for `gap` or the other side has
/// spoken for `interrupt`. Without headphones the mic hears the call, so mic speech
/// during system speech, or within `echoHangover` after it, isn't counted as you.
struct TurnTracker {
    static let echoHangover = 2  // chunks, ~0.5 s

    let gapChunks: Int
    let interruptChunks: Int
    /// Chunks stepped so far.
    private(set) var index = 0
    /// Finished turns, as chunk ranges.
    private(set) var turns: [Range<Int>] = []
    private(set) var current: (start: Int, lastSpeech: Int)?
    private var systemRun = 0
    private var lastSystemSpeech: Int?

    init(settings: TalkSettings) {
        gapChunks = max(1, Int((settings.gap / TalkMonitor.chunkSeconds).rounded(.up)))
        interruptChunks = max(1, Int((settings.interrupt / TalkMonitor.chunkSeconds).rounded(.up)))
    }

    /// Returns whether this chunk counts as you speaking.
    @discardableResult
    mutating func step(mic: Bool, system: Bool) -> Bool {
        let k = index
        index += 1
        if system {
            systemRun += 1
            lastSystemSpeech = k
        } else {
            systemRun = 0
        }
        let me = mic && lastSystemSpeech.map { k - $0 > Self.echoHangover } ?? mic
        if me {
            current = (current?.start ?? k, k)
        } else if let turn = current, systemRun >= interruptChunks || k - turn.lastSpeech >= gapChunks {
            endTurn()
        }
        return me
    }

    mutating func endTurn() {
        if let current { turns.append(current.start..<current.lastSpeech + 1) }
        current = nil
    }
}

/// `<session>/talk.json`: the VAD timeline of a meeting and the talk stats the note's
/// frontmatter carries. Times are seconds on the session timeline.
struct TalkFile: Codable {
    struct Stats: Codable {
        /// Your speech as a percentage of all speech (yours + theirs).
        var myTalkRatio: Int
        var longestTurnSeconds: Double
        var turnsOver90s: Int
        var meSeconds: Double
        var themSeconds: Double
    }

    var version = 1
    /// "live" (measured while recording) or "offline" (from the WAVs, by `rec transcribe`).
    var source: String
    var chunkSeconds: Double
    var gapSeconds: Double
    var interruptSeconds: Double
    /// Speech regions per track straight from the VAD; `me` is mic speech with echo of the system track removed.
    var speech: [String: [[Double]]]
    /// Your turns, [start, end].
    var turns: [[Double]]
    var stats: Stats
    /// Seconds the live VAD fell too far behind on and skipped (counted as silence).
    var skippedSeconds: Double?

    static let longTurn = 90.0

    /// `flags`: per-chunk speech for mic and, in a meeting, system.
    init(flags: [[Bool]], settings: TalkSettings, source: String, skippedChunks: Int = 0) {
        let c = TalkMonitor.chunkSeconds
        let mic = flags[0], system = flags.count > 1 ? flags[1] : []
        var tracker = TurnTracker(settings: settings)
        var me: [Bool] = []
        for k in 0..<max(mic.count, system.count) {
            me.append(tracker.step(mic: k < mic.count && mic[k], system: k < system.count && system[k]))
        }
        tracker.endTurn()

        func ms(_ t: Double) -> Double { (t * 1000).rounded() / 1000 }
        func regions(_ f: [Bool]) -> [[Double]] {
            var out: [[Double]] = []
            var start: Int?
            for (k, on) in (f + [false]).enumerated() {
                if on, start == nil { start = k }
                if !on, let s = start { out.append([ms(Double(s) * c), ms(Double(k) * c)]); start = nil }
            }
            return out
        }
        let meSeconds = Double(me.filter { $0 }.count) * c
        let themSeconds = Double(system.filter { $0 }.count) * c
        let lengths = tracker.turns.map { Double($0.count) * c }

        self.source = source
        chunkSeconds = c
        gapSeconds = settings.gap
        interruptSeconds = settings.interrupt
        speech = ["mic": regions(mic), "system": regions(system), "me": regions(me)]
        turns = tracker.turns.map { [ms(Double($0.lowerBound) * c), ms(Double($0.upperBound) * c)] }
        stats = Stats(
            myTalkRatio: meSeconds + themSeconds > 0 ? Int((100 * meSeconds / (meSeconds + themSeconds)).rounded()) : 0,
            longestTurnSeconds: ms(lengths.max() ?? 0),
            turnsOver90s: lengths.filter { $0 > Self.longTurn }.count,
            meSeconds: ms(meSeconds), themSeconds: ms(themSeconds))
        skippedSeconds = skippedChunks > 0 ? ms(Double(skippedChunks) * c) : nil
    }

    static func url(_ dir: URL) -> URL { dir.appendingPathComponent("talk.json") }

    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.url(dir), options: .atomic)
    }

    static func read(_ dir: URL) -> TalkFile? {
        (try? Data(contentsOf: url(dir))).flatMap { try? JSONDecoder().decode(TalkFile.self, from: $0) }
    }

    /// "you 42% · longest 02:47 · 1 turn over 90s"
    var summary: String {
        let over = stats.turnsOver90s
        return "you \(stats.myTalkRatio)% · longest \(minutesSeconds(stats.longestTurnSeconds)) · \(over) turn\(over == 1 ? "" : "s") over 90s"
    }
}

/// mm:ss (minutes keep counting past 59).
func minutesSeconds(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%02d:%02d", s / 60, s % 60)
}

/// Silero VAD (FluidAudio) on the mic and system tracks in 256 ms chunks, with the
/// turn tracker on top. While recording, the track writers hand it their samples;
/// `feed` only copies them into a buffer under a lock, and the model runs on its
/// own task, so a slow or failed VAD can never hold up capture. If it falls more
/// than `maxBacklog` behind, the oldest audio is skipped and counted as silence.
final class TalkMonitor {
    enum Track: Int { case mic, system }
    enum State: Equatable { case starting, unavailable, idle, talking(Double) }

    static let chunk = VadManager.chunkSize
    static let chunkSeconds = Double(chunk) / Double(VadManager.sampleRate)
    /// Speech regions straight from the model's hysteresis: the turn tracker handles pauses.
    private static let segmentation = VadSegmentationConfig(minSpeechDuration: 0, minSilenceDuration: 0, speechPadding: 0)
    /// Mic chunks the live turn waits for the system track before treating it as silent.
    private static let maxSystemLag = 8

    private let settings: TalkSettings
    private let tracks: Int
    private let maxBacklog: Int
    private let log: (String) -> Void

    private let lock = NSLock()
    private var pending: [[Float]]
    private var skipped: [Int]
    private var skippedTotal = 0
    private var flags: [[Bool]]
    private var live: TurnTracker
    private var _state = State.starting
    private var finishing = false
    private var started = false
    private let done = DispatchSemaphore(value: 0)

    init(settings: TalkSettings, system: Bool, maxBacklogSeconds: Double = 30, log: @escaping (String) -> Void) {
        self.settings = settings
        tracks = system ? 2 : 1
        maxBacklog = Int(maxBacklogSeconds * Double(VadManager.sampleRate))
        self.log = log
        pending = Array(repeating: [], count: tracks)
        skipped = Array(repeating: 0, count: tracks)
        flags = Array(repeating: [], count: tracks)
        live = TurnTracker(settings: settings)
    }

    var state: State { lock.withLock { _state } }

    /// Any thread (the track writers' queues). `samples` nil means `count` frames of silence.
    func feed(_ track: Track, _ samples: UnsafeBufferPointer<Float>?, count: Int) {
        let t = track.rawValue
        lock.withLock {
            guard t < tracks, _state != .unavailable, !finishing else { return }
            if let samples { pending[t].append(contentsOf: samples) }
            else { pending[t].append(contentsOf: repeatElement(0, count: count)) }
            if pending[t].count > maxBacklog {
                let drop = (pending[t].count - maxBacklog + Self.chunk - 1) / Self.chunk
                pending[t].removeFirst(drop * Self.chunk)
                skipped[t] += drop
                if skippedTotal == 0 { log("talk: VAD is falling behind; skipping audio (counted as silence)") }
                skippedTotal += drop
            }
        }
    }

    func start() {
        started = true
        Task.detached(priority: .utility) { [self] in
            defer { done.signal() }
            let vad: VadManager
            do { vad = try await VadManager() } catch { return fail("model failed to load", error) }
            var streams: [VadStreamState] = []
            for _ in 0..<tracks { streams.append(await vad.makeStreamState()) }
            lock.withLock { if _state == .starting { _state = .idle } }

            while true {
                let (work, last) = takeWork()
                if work.allSatisfy({ $0.skip == 0 && $0.chunks.isEmpty }) {
                    if last { return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                for (t, w) in work.enumerated() {
                    var out = [Bool](repeating: false, count: w.skip)
                    do {
                        for chunk in w.chunks { out.append(try await Self.isSpeech(vad, chunk, &streams[t])) }
                    } catch {
                        return fail("VAD failed", error)
                    }
                    lock.withLock { flags[t] += out }
                }
                lock.withLock { advanceLive() }
            }
        }
    }

    /// Main thread, at stop. Lets the VAD catch up (up to `timeout`) and returns the
    /// session's talk file, or nil if the VAD failed or didn't finish in time.
    func finish(timeout: TimeInterval) -> TalkFile? {
        lock.withLock { finishing = true }
        guard started else { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else {
            log("talk: VAD didn't finish in \(Int(timeout))s; `rec transcribe` measures talk time from the recording instead")
            return nil
        }
        return lock.withLock {
            _state == .unavailable ? nil
                : TalkFile(flags: flags, settings: settings, source: "live", skippedChunks: skippedTotal)
        }
    }

    /// Whole chunks waiting per track (and, when finishing, the partial last one).
    private func takeWork() -> (work: [(skip: Int, chunks: [[Float]])], last: Bool) {
        lock.withLock {
            var work: [(skip: Int, chunks: [[Float]])] = []
            for t in 0..<tracks {
                let n = finishing ? pending[t].count : pending[t].count / Self.chunk * Self.chunk
                let chunks = stride(from: 0, to: n, by: Self.chunk).map { Array(pending[t][$0..<min($0 + Self.chunk, n)]) }
                pending[t].removeFirst(n)
                work.append((skipped[t], chunks))
                skipped[t] = 0
            }
            return (work, finishing)
        }
    }

    /// Steps the live turn up to the newest mic chunk the system track has caught up with. Under `lock`.
    private func advanceLive() {
        let mic = flags[0]
        while live.index < mic.count {
            let k = live.index
            let system: Bool
            if tracks == 1 { system = false }
            else if k < flags[1].count { system = flags[1][k] }
            else if mic.count - k > Self.maxSystemLag { system = false }
            else { break }
            live.step(mic: mic[k], system: system)
        }
        if _state != .unavailable {
            _state = live.current.map { .talking(Double(live.index - $0.start) * Self.chunkSeconds) } ?? .idle
        }
    }

    private func fail(_ what: String, _ error: Error) {
        lock.withLock {
            _state = .unavailable
            pending = Array(repeating: [], count: tracks)
        }
        log("talk: \(what) (\(error.localizedDescription)); the talk-time dot is off, recording continues")
    }

    private static func isSpeech(_ vad: VadManager, _ chunk: [Float], _ stream: inout VadStreamState) async throws -> Bool {
        let result = try await vad.processStreamingChunk(chunk, state: stream, config: segmentation)
        stream = result.state
        return result.state.triggered
    }

    /// The same VAD and turns over a meeting's WAVs, for sessions recorded without a live
    /// timeline (older ones, or the live VAD failed).
    static func analyze(dir: URL, settings: TalkSettings) async throws -> TalkFile {
        let vad = try await VadManager()
        var flags: [[Bool]] = []
        for name in ["mic.wav", "system.wav"] {
            let samples = try AudioConverter().resampleAudioFile(dir.appendingPathComponent(name))
            var stream = await vad.makeStreamState()
            var out: [Bool] = []
            out.reserveCapacity(samples.count / chunk + 1)
            for start in stride(from: 0, to: samples.count, by: chunk) {
                out.append(try await isSpeech(vad, Array(samples[start..<min(start + chunk, samples.count)]), &stream))
            }
            flags.append(out)
        }
        return TalkFile(flags: flags, settings: settings, source: "offline")
    }
}

/// The talk-time dot in the menu bar: a hollow ring while you're not talking, then
/// green, amber at `amberSeconds` and red at `redSeconds` into a turn. It's a status
/// item, not a window, so sharing a window never shows it; it also asks to be left
/// out of full-screen captures. No notifications, sounds or popups.
final class TalkIndicator {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: TalkSettings
    private var shown: (TalkSettings.Level, String)?

    private static let images: [TalkSettings.Level: NSImage] = [
        .idle: dot(nil), .green: dot(.systemGreen), .amber: dot(.systemOrange), .red: dot(.systemRed),
    ]

    /// Main thread.
    init(settings: TalkSettings) {
        self.settings = settings
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.toolTip = "rec: how long you've been talking"
        item.button?.window?.sharingType = .none
        update(.idle)
    }

    /// Main thread.
    func update(_ state: TalkMonitor.State) {
        let level = settings.level(state)
        var title = ""
        if settings.seconds, case .talking(let elapsed) = state { title = " \(Int(elapsed))s" }
        guard shown?.0 != level || shown?.1 != title else { return }
        shown = (level, title)
        item.button?.image = Self.images[level]
        item.button?.title = title
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    private static func dot(_ color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if let color {
                color.setFill()
                circle.fill()
            } else {
                NSColor.black.setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

/// `rec _talk DIR [--live] [--speed N]`, a testing aid. Runs the VAD over a meeting's WAVs
/// and prints your turns, the stats and each time the dot would change colour.
/// `--live` instead plays the WAVs through the live monitor and the real menu bar dot,
/// at N× real time (default 1), printing each change as it happens.
enum TalkCommand {
    static func run(_ args: [String]) -> Never {
        guard let path = args.first else { fail("usage: rec _talk DIR [--live] [--speed N]", code: 64) }
        let dir = URL(fileURLWithPath: path)
        let settings = Config.load()?.talk ?? TalkSettings()
        let speed = args.firstIndex(of: "--speed").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 1
        if args.contains("--live") { live(dir: dir, settings: settings, speed: speed) }

        Task {
            do {
                let file = try await TalkMonitor.analyze(dir: dir, settings: settings)
                // Replay the turns chunk by chunk, as the live dot would see them.
                var tracker = TurnTracker(settings: settings)
                var last = TalkSettings.Level.idle
                let me = flags(file.speech["mic"] ?? [], file), them = flags(file.speech["system"] ?? [], file)
                for k in 0..<max(me.count, them.count) {
                    tracker.step(mic: k < me.count && me[k], system: k < them.count && them[k])
                    let state = tracker.current.map { TalkMonitor.State.talking(Double(tracker.index - $0.start) * file.chunkSeconds) } ?? .idle
                    let level = settings.level(state)
                    if level != last {
                        print("\(clock(Double(tracker.index) * file.chunkSeconds))  \(level.rawValue)")
                        last = level
                    }
                }
                for t in file.turns where t[1] - t[0] >= 10 {
                    print(String(format: "turn %@–%@  %@", clock(t[0]), clock(t[1]), minutesSeconds(t[1] - t[0])))
                }
                print("\(file.turns.count) turns; \(file.summary); me \(Int(file.stats.meSeconds))s, them \(Int(file.stats.themSeconds))s")
                exit(0)
            } catch {
                fail("talk: \(error.localizedDescription)")
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func flags(_ regions: [[Double]], _ file: TalkFile) -> [Bool] {
        var out: [Bool] = []
        for r in regions {
            let a = Int((r[0] / file.chunkSeconds).rounded()), b = Int((r[1] / file.chunkSeconds).rounded())
            out += [Bool](repeating: false, count: max(0, a - out.count)) + [Bool](repeating: true, count: b - a)
        }
        return out
    }

    private static func live(dir: URL, settings: TalkSettings, speed: Double) -> Never {
        let monitor = TalkMonitor(settings: settings, system: true) { print("log: \($0)") }
        let tracks: [[Float]]
        do {
            tracks = try ["mic.wav", "system.wav"].map { try AudioConverter().resampleAudioFile(dir.appendingPathComponent($0)) }
        } catch {
            fail("talk: \(error.localizedDescription)")
        }
        let block = 1_600  // 100 ms, like a capture buffer
        let fed = ManagedAtomicCounter()
        monitor.start()
        DispatchQueue.global(qos: .userInitiated).async {
            let total = tracks.map(\.count).max() ?? 0
            for start in stride(from: 0, to: total, by: block) {
                for (t, samples) in tracks.enumerated() where start < samples.count {
                    samples[start..<min(start + block, samples.count)].withUnsafeBufferPointer {
                        monitor.feed(TalkMonitor.Track(rawValue: t)!, $0, count: $0.count)
                    }
                }
                fed.set(start + block)
                Thread.sleep(forTimeInterval: Double(block) / Double(VadManager.sampleRate) / speed)
            }
            DispatchQueue.main.async {
                let file = monitor.finish(timeout: 10)
                print(file.map { "done: \($0.turns.count) turns; \($0.summary)" } ?? "done: no talk file")
                exit(0)
            }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let indicator = TalkIndicator(settings: settings)
        var last: TalkSettings.Level?
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            let state = monitor.state
            indicator.update(state)
            let level = settings.level(state)
            guard level != last else { return }
            last = level
            var into = ""
            if case .talking(let s) = state { into = String(format: "  (%.1fs into turn)", s) }
            print("\(clock(Double(fed.get()) / Double(VadManager.sampleRate)))  \(level.rawValue)\(into)")
        }
        RunLoop.main.add(timer, forMode: .common)
        NSApplication.shared.run()
        exit(0)
    }
}

private final class ManagedAtomicCounter {
    private let lock = NSLock()
    private var value = 0
    func set(_ v: Int) { lock.withLock { value = v } }
    func get() -> Int { lock.withLock { value } }
}
