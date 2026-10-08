import AVFoundation
import Foundation
import SQLite3

/// `rec import [FILE] [--memo latest] [--as dictation|conversation] [--title TEXT] [--no-transcribe]`:
/// turns an existing recording into a session. With no FILE it lists Voice Memos
/// to pick from. The audio is decoded (anything AVFoundation reads, including the
/// sound of a video), mixed to mono and resampled to `audio.wav` at 16 kHz in a
/// session named after when it was recorded, then transcribed like a recording
/// that just stopped. The original stays where it is; session.json points at it,
/// so importing the same file or memo again finds the existing session.
enum Importer {
    struct Source {
        let url: URL
        var memoID: String?
        var title: String?
        var recorded: Date?
    }

    static func run(_ args: [String]) -> Never {
        var path: String?
        var latestMemo = false
        var kind: String?
        var title: String?
        var transcribe = true
        var rest = args[...]
        func value(_ flag: String) -> String {
            guard let v = rest.popFirst() else { fail("\(flag) needs a value", code: 64) }
            return v
        }
        while let arg = rest.popFirst() {
            switch arg {
            case "--memo":
                let v = value(arg)
                guard v == "latest" else { fail("--memo takes `latest` (run `rec import` with no file to pick one)", code: 64) }
                latestMemo = true
            case "--as":
                let v = value(arg)
                guard ImportKind(rawValue: v) != nil else { fail("--as must be dictation or conversation, not \(v)", code: 64) }
                kind = v
            case "--title": title = value(arg)
            case "--no-transcribe": transcribe = false
            case _ where arg.hasPrefix("-"): fail("unknown option \(arg)\n\(usage)", code: 64)
            case _ where path == nil: path = arg
            default: fail("unexpected argument \(arg)\n\(usage)", code: 64)
            }
        }
        if path != nil, latestMemo { fail("give a file or --memo latest, not both", code: 64) }

        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        var source: Source
        if let path {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: url.path) else { fail("cannot read \(Style.path(url.path))") }
            source = Source(url: url)
        } else {
            let memos: [VoiceMemos.Memo]
            do { memos = try VoiceMemos.list() } catch { fail(error.localizedDescription) }
            guard !memos.isEmpty else { fail("no Voice Memos on this Mac") }
            let memo: VoiceMemos.Memo
            if latestMemo {
                memo = memos[0]
            } else {
                guard interactive, let term = RawTerminal() else {
                    fail("no terminal to pick a memo in; pass a file or --memo latest", code: 64)
                }
                memo = pickMemo(memos, imported: importedMemoIDs(), term: term)
            }
            source = Source(url: memo.url, memoID: memo.id, title: memo.title, recorded: memo.date)
        }
        if let title { source.title = title }
        if transcribe { Launcher.checkTranscription(interactive: interactive) }

        if let existing = existingSession(for: source) {
            let note = (try? String(contentsOf: existing.appendingPathComponent(".note"), encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
            print("\(Style.ok) already imported  \(Style.path(existing.path))")
            if let note, let config = Config.load() {
                print("  \(Style.dim("note"))  \(Style.path(config.transcriptionsDir.appendingPathComponent(note).path))")
                print(Style.dim("  run `rec transcribe \(existing.path)` to transcribe it again"))
                exit(0)
            }
            guard transcribe else { exit(0) }
            Transcriber.runAttached(dir: existing.path)
        }

        Task {
            let dir: URL
            do {
                dir = try await importAudio(source, as: kind)
            } catch {
                fail("import failed: \(error.localizedDescription)")
            }
            guard transcribe else {
                print(Style.dim("  transcribe it with `rec transcribe \(dir.path)`"))
                exit(0)
            }
            Transcriber.runAttached(dir: dir.path)
        }
        dispatchMain()
    }

    /// Decodes the source into a new session directory and writes its session.json.
    private static func importAudio(_ source: Source, as kind: String?) async throws -> URL {
        let asset = AVURLAsset(url: source.url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TranscribeError("\(source.url.lastPathComponent) has no audio track") }
        var recorded = source.recorded
        if recorded == nil, let item = try? await asset.load(.creationDate) {
            recorded = try? await item.load(.dateValue)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.url.path)
        let start = recorded ?? attributes?[.creationDate] as? Date ?? attributes?[.modificationDate] as? Date ?? Date()

        let dir = newSessionDir(start: start)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let label = source.title.map { "importing \(Style.bold($0))" } ?? "importing \(Style.path(source.url.lastPathComponent))"
        let spinner = TranscribeProgress(terminal: STDOUT_FILENO, logs: false)
        defer { spinner.finish() }
        spinner.begin(label)
        let frames: Int64
        do {
            let total = try await asset.load(.duration).seconds
            frames = try decode(asset: asset, tracks: tracks, to: dir.appendingPathComponent("audio.wav")) { seconds in
                if total > 0 { spinner.update("\(label)  \(Style.dim(String(format: "%.0f%%", min(100, seconds / total * 100))))") }
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let duration = Double(frames) / TrackWriter.sampleRate
        spinner.end("\(Style.ok) imported \(clock(duration))  \(Style.dim("recorded \(start.formatted(date: .abbreviated, time: .shortened))"))")

        var session = SessionInfo(start: iso8601.string(from: start),
                                  startEpochMs: Int64((start.timeIntervalSince1970 * 1000).rounded()))
        session.mode = "import"
        session.files = ["audio": "audio.wav"]
        session.source = .init(path: source.url.path, memoID: source.memoID, title: source.title)
        session.importAs = kind
        session.end = iso8601.string(from: start.addingTimeInterval(duration))
        session.durationSeconds = duration
        session.frames = frames
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: dir.appendingPathComponent("session.json"))
        print("  \(Style.dim("session"))  \(Style.path(dir.path))")
        return dir
    }

    /// Every audio track mixed to 16 kHz mono and written as 16-bit PCM. Returns the frame count.
    private static func decode(asset: AVAsset, tracks: [AVAssetTrack], to url: URL,
                               progress: (Double) -> Void) throws -> Int64 {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TrackWriter.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranscribeError("cannot read \(url.lastPathComponent)") }
        let writer = try WAVWriter(url: url, sampleRate: Int(TrackWriter.sampleRate))
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            samples = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            try samples.withUnsafeMutableBytes { raw in
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!) == noErr else {
                    throw TranscribeError("could not read decoded audio")
                }
            }
            try samples.withUnsafeBufferPointer { try writer.append($0) }
            progress(Double(writer.frames) / TrackWriter.sampleRate)
        }
        if reader.status == .failed { throw reader.error ?? TranscribeError("decoding failed") }
        try writer.close()
        return writer.frames
    }

    /// `~/Recordings/rec/<yyyy-MM-dd_HHmmss>` for when it was recorded, with a suffix if that's taken.
    private static func newSessionDir(start: Date) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = f.string(from: start)
        for n in 1... {
            let dir = Paths.recordingsRoot.appendingPathComponent(n == 1 ? base : "\(base)_\(n)", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) { return dir }
        }
        fatalError("unreachable")
    }

    private static func importedSessions() -> [(dir: URL, source: SessionInfo.Source)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("session.json")))
                .flatMap { try? JSONDecoder().decode(SessionInfo.self, from: $0) }?.source.map { (dir, $0) }
        }
    }

    private static func importedMemoIDs() -> Set<String> {
        Set(importedSessions().compactMap(\.source.memoID))
    }

    private static func existingSession(for source: Source) -> URL? {
        importedSessions().first { _, s in
            if let id = source.memoID { return s.memoID == id }
            return s.memoID == nil && s.path == source.url.path
        }?.dir
    }

    /// Scrolling arrow-key list of memos, newest first: ↑/↓ (or j/k, Tab) to move,
    /// Enter to choose, Esc/q/Ctrl-C to cancel. Collapses to a one-line summary once chosen.
    private static func pickMemo(_ memos: [VoiceMemos.Memo], imported: Set<String>, term: RawTerminal) -> VoiceMemos.Memo {
        let height = min(memos.count, 10)
        var cursor = 0, top = 0, drawnLines = 0
        let thisYear = Calendar.current.component(.year, from: Date())
        let dateFormat = DateFormatter()
        func when(_ d: Date) -> String {
            dateFormat.dateFormat = "MMM d"
            let day = dateFormat.string(from: d).padding(toLength: 6, withPad: " ", startingAt: 0)
            dateFormat.dateFormat = Calendar.current.component(.year, from: d) == thisYear ? "HH:mm" : "yyyy"
            return "\(day) \(dateFormat.string(from: d))"
        }
        let names = memos.map { String(($0.title ?? "New Recording").prefix(40)) }
        let nameWidth = names.map(\.count).max() ?? 0
        let dates = memos.map { when($0.date) }
        let dateWidth = dates.map(\.count).max() ?? 0

        func rewind() -> String {
            (drawnLines > 1 ? "\u{1B}[\(drawnLines - 1)A" : "") + "\r\u{1B}[J"
        }
        func draw() {
            if cursor < top { top = cursor }
            if cursor >= top + height { top = cursor - height + 1 }
            var lines = [Style.bold("Which voice memo?") + "  " + Style.dim("\(memos.count) on this Mac, newest first")]
            for i in top..<top + height {
                let selected = i == cursor
                let pointer = selected ? Style.strong("❯", Style.accent) : " "
                let name = Style.pad(selected ? Style.strong(names[i], Style.accent) : names[i], nameWidth)
                let done = imported.contains(memos[i].id) ? Style.fg("✓ imported", Style.green) : ""
                lines.append("\(pointer) \(name)  \(Style.dim(Style.pad(dates[i], dateWidth)))  \(Style.dim(clock(memos[i].duration)))  \(done)")
            }
            let more = memos.count > height ? " · \(cursor + 1)/\(memos.count)" : ""
            lines.append(Style.faint("↑↓ move · enter choose · esc cancel\(more)"))
            term.write(rewind() + lines.joined(separator: "\n"))
            drawnLines = lines.count
        }
        draw()
        while true {
            switch term.readKey() {
            case .up, .char("k"): cursor = (cursor - 1 + memos.count) % memos.count
            case .down, .char("j"), .char("\t"): cursor = (cursor + 1) % memos.count
            case .enter:
                term.write(rewind())
                term.restore()
                print("\(Style.ok) \(Style.dim("memo")) \(Style.bold(names[cursor]))  \(Style.dim(dates[cursor]))")
                return memos[cursor]
            case .cancel, .char("q"):
                term.write(rewind())
                term.restore()
                print(Style.dim("○ cancelled"))
                exit(130)
            default: break
            }
            draw()
        }
    }
}

/// How an imported recording is written up: one voice thinking aloud, or several people talking.
enum ImportKind: String { case dictation, conversation }

/// The Voice Memos library: `CloudRecordings.db` and the .m4a files beside it.
enum VoiceMemos {
    struct Memo {
        let id: String
        let title: String?
        let date: Date
        let duration: Double
        let url: URL
    }

    static let folder = Paths.home.appendingPathComponent(
        "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)

    /// Memos whose audio is on this Mac, newest first. Recently Deleted ones are left out.
    static func list() throws -> [Memo] {
        let dbPath = folder.appendingPathComponent("CloudRecordings.db").path
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
            throw TranscribeError("""
                can't read the Voice Memos library. Give your terminal Full Disk Access \
                (System Settings › Privacy & Security › Full Disk Access), or export the memo \
                from Voice Memos and run `rec import FILE`
                """)
        }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw TranscribeError("cannot open \(dbPath)")
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT * FROM ZCLOUDRECORDING WHERE ZPATH IS NOT NULL AND ZEVICTIONDATE IS NULL ORDER BY ZDATE DESC",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw TranscribeError("unexpected Voice Memos database: \(String(cString: sqlite3_errmsg(db)))")
        }
        var columns: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(stmt) { columns[String(cString: sqlite3_column_name(stmt, i))] = i }
        func text(_ name: String) -> String? {
            guard let i = columns[name], let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func number(_ name: String) -> Double {
            columns[name].map { sqlite3_column_double(stmt, $0) } ?? 0
        }
        var memos: [Memo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let path = text("ZPATH") else { continue }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            memos.append(Memo(
                id: text("ZUNIQUEID") ?? url.deletingPathExtension().lastPathComponent,
                title: cleanTitle(text("ZENCRYPTEDTITLE")) ?? cleanTitle(text("ZCUSTOMLABEL")),
                date: Date(timeIntervalSinceReferenceDate: number("ZDATE")),
                duration: number("ZDURATION"),
                url: url))
        }
        return memos
    }

    /// A name someone gave the memo, or nil for Voice Memos' defaults ("New Recording 4", a timestamp).
    private static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = raw.filter { !"\u{200E}\u{200F}\u{FEFF}".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.range(of: #"^New Recording( \d+)?$"#, options: .regularExpression) != nil { return nil }
        if ISO8601DateFormatter().date(from: title) != nil { return nil }
        return title
    }
}
