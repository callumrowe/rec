import FluidAudio
import Foundation

/// `rec transcribe [DIR]`: Parakeet ASR on both tracks, speaker diarization on
/// system.wav, merged on the shared timeline into `<vault>/transcriptions/`.
/// mic.wav is "Me"; remote voices are "Them", or "Speaker N" when the diarizer
/// hears more than one.
enum Transcriber {
    static func run(_ args: [String], background: Bool = false) -> Never {
        let dir: URL
        if let path = args.first {
            dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let latest = latestSession() {
            dir = latest
        } else {
            fail("no sessions in \(Paths.recordingsRoot.path)")
        }
        guard let config = Config.load() else { fail("no Obsidian vault configured; run `rec config`") }
        if let problem = Vault.check(config.vault) { fail("\(problem); run `rec config`") }

        // One transcription per session at a time (`rec stop` and a foreground `rec start` may both launch one).
        let lockFD = open(dir.appendingPathComponent(".transcribe.lock").path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            print("\(Style.warn) \(Style.path(dir.path)) is already being transcribed")
            exit(0)
        }

        // FluidAudio and Core ML write diagnostics straight to stdout/stderr; send
        // those to the log and keep the terminal for our own progress lines.
        // (Style decides on colour from stdout, so settle that while it's the terminal.)
        let log = dir.appendingPathComponent("transcribe.log").path
        var terminal: Int32?
        if !background {
            _ = Style.enabled
            let fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                fflush(stdout)
                terminal = dup(STDOUT_FILENO)
                dup2(fd, STDOUT_FILENO)
                dup2(fd, STDERR_FILENO)
                close(fd)
            }
        }
        progress = TranscribeProgress(terminal: terminal)
        func done(_ code: Int32) -> Never {
            progress.finish()
            // The marker a foreground `rec start` left for `rec stop`; this process is its exec.
            let marker = dir.appendingPathComponent(".attached.pid")
            if (try? String(contentsOf: marker, encoding: .utf8)) == "\(getpid())\n" {
                try? FileManager.default.removeItem(at: marker)
            }
            exit(code)
        }

        // In a terminal, Ctrl-C cancels. Closing the terminal doesn't: the note
        // still gets written, with progress going to the log.
        if !background {
            signal(SIGHUP, SIG_IGN)
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    progress.cancel("\(Style.dim("○ transcription cancelled; finish it with")) rec transcribe \(Style.path(dir.path))")
                    done(130)
                }
                source.resume()
                signalSources.append(source)
            }
        }

        Task {
            do {
                let note = try await transcribe(dir: dir, config: config)
                progress.line("\(Style.ok) transcript → \(Style.path(note.path))")
                if background { notify("Transcript saved", note.deletingPathExtension().lastPathComponent) }
                done(0)
            } catch {
                progress.cancel("\(Style.bad) transcription failed: \(error.localizedDescription) (details in \(Style.path(log)))")
                if background { notify("Transcription failed", "\(error.localizedDescription) — see transcribe.log") }
                done(1)
            }
        }
        dispatchMain()
    }

    /// After a foreground `rec start`: becomes `rec transcribe DIR` in this same
    /// process, so the terminal shows progress and the prompt comes back when
    /// the note is written.
    static func runAttached(dir: String) -> Never {
        guard vaultConfigured() else { exit(0) }
        print("")
        fflush(stdout)
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_DFL) }
        let exe = executablePath()
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("transcribe"), strdup(dir), nil]
        execv(exe, argv)
        fputs("\(Style.bad) could not run \(exe) (\(String(cString: strerror(errno))))\n", stderr)
        launchInBackground(dir: dir)
        exit(1)
    }

    /// Starts `rec _transcribe DIR` in its own session so it outlives this
    /// terminal, logging to `<DIR>/transcribe.log`. It runs from the CLI rather
    /// than Rec.app so writing into the vault uses the terminal's file access.
    static func launchInBackground(dir: String) {
        guard vaultConfigured() else { return }
        let log = URL(fileURLWithPath: dir).appendingPathComponent("transcribe.log").path
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let exe = executablePath()
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("_transcribe"), strdup(dir), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, exe, &actions, &attr, argv, environ)
        if status == 0 {
            print("  \(Style.dim("transcript"))  in the background, log at \(Style.path(log))")
        } else {
            fputs("\(Style.bad) could not start transcription (\(String(cString: strerror(status)))); run `rec transcribe \(dir)`\n", stderr)
        }
    }

    private static func vaultConfigured() -> Bool {
        guard Config.load() == nil else { return true }
        print("\(Style.warn) not transcribing; run `rec config` to choose an Obsidian vault, then `rec transcribe`")
        return false
    }

    nonisolated(unsafe) private static var progress = TranscribeProgress(terminal: nil)
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    // MARK: - Pipeline

    private static func transcribe(dir: URL, config: Config) async throws -> URL {
        let micURL = dir.appendingPathComponent("mic.wav")
        let systemURL = dir.appendingPathComponent("system.wav")
        for url in [micURL, systemURL] where !FileManager.default.fileExists(atPath: url.path) {
            throw TranscribeError("missing \(url.path)")
        }
        let session = (try? Data(contentsOf: dir.appendingPathComponent("session.json")))
            .flatMap { try? JSONDecoder().decode(SessionInfo.self, from: $0) }
        let started = Date()
        let audio = session?.durationSeconds.map { "  " + Style.dim("\(shortDuration($0)) of audio") } ?? ""
        progress.line("\(Style.strong("◆", Style.accent)) \(Style.bold("transcribing"))  \(Style.path(dir.path))\(audio)")

        let version: AsrModelVersion = config.model == "v3" ? .v3 : .v2
        let model = "Parakeet \(config.model ?? "v2")"
        progress.begin("loading \(model) \(Style.dim("(the first run downloads the models)"))")
        let asr = AsrManager(config: .default)
        try await asr.loadModels(try await AsrModels.downloadAndLoad(version: version))
        progress.end(Style.event("✓ model: \(model) loaded"))

        func words(_ url: URL) async throws -> [WordTiming] {
            var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
            let result = try await asr.transcribe(url, decoderState: &state)
            return buildWordTimings(from: result.tokenTimings ?? [])
        }
        progress.begin("transcribing mic")
        let micWords = try await words(micURL)
        progress.end(Style.event("✓ mic: \(micWords.count) words"))
        progress.begin("transcribing system audio")
        let systemWords = try await words(systemURL)
        progress.end(Style.event("✓ system: \(systemWords.count) words"))
        await asr.cleanup()

        var speakers: [Transcript.SpeakerSpan] = []
        if !systemWords.isEmpty {
            progress.begin("finding speakers in system audio")
            do {
                let diarizer = OfflineDiarizerManager(config: OfflineDiarizerConfig())
                try await diarizer.prepareModels()
                speakers = try await diarizer.process(systemURL).segments.map {
                    .init(id: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
                }
                for s in speakers { fputs(String(format: "diarization: %@ %.2f–%.2f\n", s.id, s.start, s.end), stderr) }
                progress.end(Style.event("✓ speakers: \(Set(speakers.map(\.id)).count) in system audio"))
            } catch {
                // Still worth a transcript; remote speech is just labelled "Them".
                progress.end(Style.event("⚠ diarization failed (\(error.localizedDescription)); labelling remote speech \"Them\""))
            }
        }

        let transcript = Transcript(mic: micWords, system: systemWords, speakers: speakers)
        let startDate = session.map { Date(timeIntervalSince1970: Double($0.startEpochMs) / 1000) }
            ?? (try? FileManager.default.attributesOfItem(atPath: micURL.path)[.creationDate] as? Date)
            ?? Date()
        let micName = session.map { s in
            s.micName ?? AudioDevices.device(uid: s.micDeviceUID).flatMap(AudioDevices.name) ?? s.micDeviceUID
        }
        let note = transcript.markdown(
            start: startDate, duration: session?.durationSeconds, mic: micName,
            session: dir.path, model: version == .v3 ? "parakeet-tdt-0.6b-v3" : "parakeet-tdt-0.6b-v2")

        try Vault.ensureTranscriptionsDir(config)
        let url = noteURL(in: config.transcriptionsDir, start: startDate, session: dir.path)
        try note.write(to: url, atomically: true, encoding: .utf8)
        progress.line(Style.dim(String(format: "  %d turns, %d echo words dropped from the mic, %@ in all",
                                       transcript.utterances.count, transcript.droppedEcho,
                                       shortDuration(Date().timeIntervalSince(started)))))
        return url
    }

    /// `2026-09-23 14-30 Transcript.md`. Re-running a session overwrites its own
    /// note; another session that started in the same minute gets a " 2" suffix.
    private static func noteURL(in folder: URL, start: Date, session: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "\(f.string(from: start)) Transcript"
        let marker = "session: \(yamlString(session))\n"
        for n in 1... {
            let url = folder.appendingPathComponent(n == 1 ? "\(base).md" : "\(base) \(n).md")
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return url }
            if existing.contains(marker) { return url }
        }
        fatalError("unreachable")
    }

    private static func executablePath() -> String {
        var size = UInt32(PATH_MAX)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return CommandLine.arguments[0] }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }

    private static func notify(_ title: String, _ message: String) {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \(quoted(message)) with title \"rec\" subtitle \(quoted(title))"]
        try? p.run()
        p.waitUntilExit()
    }
}

struct TranscribeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Progress lines go to the log (unstyled) and, in the foreground, to the
/// terminal, where the running step is a spinner with its elapsed time that
/// turns into a summary line when the step ends.
final class TranscribeProgress: @unchecked Sendable {
    private let terminal: Int32?
    private let live: Bool
    private let lock = NSLock()
    private var step: (label: String, start: Date)?
    private var stepDrawn = false
    private var frame = 0
    private var timer: DispatchSourceTimer?
    private var savedTerm: termios?
    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(terminal: Int32?) {
        self.terminal = terminal
        live = terminal.map { isatty($0) != 0 } == true && Style.enabled
        guard live else { return }
        // Keystrokes (and "^C") would land in the middle of the spinner line.
        var term = termios()
        if isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &term) == 0 {
            savedTerm = term
            term.c_lflag &= ~tcflag_t(ECHOCTL | ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &term)
        }
        show("\u{1B}[?25l")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func line(_ message: String) {
        lock.withLock {
            log(message)
            show(clearStep() + message + "\n" + drawStep())
        }
    }

    func begin(_ label: String) {
        lock.withLock {
            log(label)
            step = (label, Date())
            if live { show(clearStep() + drawStep()) } else { show(label + "\n") }
        }
    }

    /// Ends the running step with a summary and how long it took.
    func end(_ summary: String) {
        let took = lock.withLock { () -> TimeInterval in
            defer { step = nil }
            return step.map { Date().timeIntervalSince($0.start) } ?? 0
        }
        line(summary + "  " + Style.faint(shortDuration(took)))
    }

    /// Drops the running step, if any, for a final message.
    func cancel(_ message: String) {
        lock.withLock { step = nil }
        line(message)
    }

    /// Stops the spinner and gives the terminal back.
    func finish() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            step = nil
            show(clearStep())
            if live { show("\u{1B}[?25h") }
            if var term = savedTerm { tcsetattr(STDIN_FILENO, TCSANOW, &term) }
            savedTerm = nil
        }
    }

    private func tick() {
        lock.withLock {
            guard step != nil else { return }
            frame += 1
            show(clearStep() + drawStep())
        }
    }

    private func drawStep() -> String {
        guard live, let step else { return "" }
        stepDrawn = true
        let glyph = Style.fg(Self.spinner[frame % Self.spinner.count], Style.accent)
        return "\(glyph) \(step.label)  \(Style.faint(shortDuration(Date().timeIntervalSince(step.start))))"
    }

    private func clearStep() -> String {
        guard stepDrawn else { return "" }
        stepDrawn = false
        return "\r\u{1B}[2K"
    }

    private func show(_ s: String) {
        guard let terminal, !s.isEmpty else { return }
        _ = s.withCString { write(terminal, $0, strlen($0)) }
    }

    private func log(_ message: String) {
        print(Style.plain(message))
        fflush(stdout)
    }
}

/// "42s", "3m 05s", "1h 02m".
func shortDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
    return String(format: "%dh %02dm", s / 3600, (s / 60) % 60)
}

// MARK: - Merging

/// Word timings from both tracks, merged into speaker turns on the session timeline.
struct Transcript {
    struct SpeakerSpan { let id: String; let start: Double; let end: Double }
    struct Utterance { let speaker: String; let start: Double; let text: String }

    private(set) var utterances: [Utterance] = []
    private(set) var speakerNames: [String] = []
    /// Mic words dropped because they were the speakers leaking into the mic.
    private(set) var droppedEcho = 0

    init(mic: [WordTiming], system: [WordTiming], speakers: [SpeakerSpan]) {
        // Remote speech: cut into sentences (or pause-separated fragments), then
        // give each the diarized speaker most of its words fall in, so a label
        // can't flip mid-sentence. Speakers are numbered in order of first speech.
        let phrases = Self.turns(system.map { ($0, "") }, pause: 0.6, sentencePause: -1)
        var ids = phrases.map { Self.dominantSpeaker($0.words, speakers) }
        for i in ids.indices where ids[i] == nil {
            ids[i] = i > 0 ? ids[i - 1] : ids.lazy.compactMap { $0 }.first
        }
        var order: [String] = []
        for case let id? in ids where !order.contains(id) { order.append(id) }
        let remote = Dictionary(uniqueKeysWithValues: order.enumerated().map { i, id in
            (id, order.count > 1 ? "Speaker \(i + 1)" : "Them")
        })
        let labelled = zip(phrases, ids).flatMap { phrase, id in
            phrase.words.map { ($0, id.flatMap { remote[$0] } ?? "Them") }
        }
        let remoteTurns = Self.turns(labelled)

        // Without headphones the mic also hears the call. Drop mic words the
        // system track said at the same moment, plus short misheard runs
        // sandwiched between them, before grouping what's left into turns.
        let heard = Dictionary(grouping: system, by: { Self.normalized($0.word) }).mapValues { $0.map(\.startTime) }
        var echo = mic.map { w in
            let key = Self.normalized(w.word)
            return !key.isEmpty && (heard[key] ?? []).contains { abs($0 - w.startTime) < 0.8 }
        }
        var i = 0
        while i < mic.count {
            guard !echo[i] else { i += 1; continue }
            var j = i
            while j < mic.count, !echo[j] { j += 1 }
            if i > 0, j < mic.count, j - i <= 2,
               mic[i].startTime - mic[i - 1].endTime < 1, mic[j].startTime - mic[j - 1].endTime < 1 {
                for k in i..<j { echo[k] = true }
            }
            i = j
        }
        droppedEcho = echo.filter { $0 }.count
        let micTurns = Self.turns(zip(mic, echo).compactMap { $1 ? nil : ($0, "Me") })

        utterances = (micTurns + remoteTurns)
            .sorted { $0.words[0].startTime < $1.words[0].startTime }
            .map { Utterance(speaker: $0.speaker, start: $0.words[0].startTime,
                             text: $0.words.map(\.word).joined(separator: " ")) }
        speakerNames = (micTurns.isEmpty ? [] : ["Me"])
            + (order.isEmpty ? (remoteTurns.isEmpty ? [] : ["Them"]) : order.compactMap { remote[$0] })
    }

    /// The diarized speaker most of these words fall in (by word midpoint), or
    /// the nearest one within a second when none do.
    private static func dominantSpeaker(_ words: [WordTiming], _ speakers: [SpeakerSpan]) -> String? {
        var votes: [String: Int] = [:]
        for word in words {
            let mid = (word.startTime + word.endTime) / 2
            if let hit = speakers.first(where: { $0.start <= mid && mid <= $0.end }) { votes[hit.id, default: 0] += 1 }
        }
        if let best = votes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { return best.key }
        guard let first = words.first, let last = words.last else { return nil }
        let mid = (first.startTime + last.endTime) / 2
        return speakers.min { distance(mid, $0) < distance(mid, $1) }.flatMap { distance(mid, $0) <= 1 ? $0.id : nil }
    }

    private struct Turn { let speaker: String; var words: [WordTiming] }

    /// Splits one track into turns: on speaker change, a long pause, or a
    /// shorter pause after a sentence ends. Long monologues break at sentences.
    private static func turns(_ words: [(WordTiming, String)], pause: Double = 2, sentencePause: Double = 0.8) -> [Turn] {
        var result: [Turn] = []
        for (word, speaker) in words {
            if var last = result.last, last.speaker == speaker, let prev = last.words.last {
                let gap = word.startTime - prev.endTime
                let sentenceEnded = prev.word.last.map { ".?!".contains($0) } ?? false
                let long = word.startTime - last.words[0].startTime > 45
                if gap < pause && !(sentenceEnded && (gap > sentencePause || long)) {
                    last.words.append(word)
                    result[result.count - 1] = last
                    continue
                }
            }
            result.append(Turn(speaker: speaker, words: [word]))
        }
        return result
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func markdown(start: Date, duration: Double?, mic: String?, session: String, model: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        var lines = ["---", "date: \(iso.string(from: start))"]
        if let duration { lines.append("duration: \(yamlString(clock(duration)))") }
        if let mic { lines.append("mic: \(yamlString(mic))") }
        lines.append("speakers:")
        lines += speakerNames.map { "  - \(yamlString($0))" }
        lines += ["session: \(yamlString(session))", "model: \(model)", "tags:", "  - transcript", "---", ""]
        if utterances.isEmpty {
            lines.append("_No speech detected._")
        } else {
            lines += utterances.map { "**[\(clock($0.start))] \($0.speaker):** \($0.text)\n" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private func distance(_ t: Double, _ span: Transcript.SpeakerSpan) -> Double {
    t < span.start ? span.start - t : max(0, t - span.end)
}

/// Double-quoted YAML scalar.
func yamlString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
