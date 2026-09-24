import Foundation

/// `<session>/transcript.<engine>.json`: the same schema whichever engine ran,
/// so runs of different engines on one session sit side by side for comparison.
/// Times are seconds on the session timeline.
struct TranscriptFile: Codable {
    struct Timing: Codable {
        /// Loading (and on first run downloading) the engine's models.
        var modelLoadSeconds: Double
        /// Speech to words for the chosen tracks (for Whisper, including VAD).
        var transcribeSeconds: Double
        /// The two together: what this engine cost end to end. Excludes diarization, which is shared.
        var wallClockSeconds: Double
    }
    struct TimedWord: Codable { var word: String; var start: Double; var end: Double }
    struct Words: Codable { var mic: [TimedWord]?; var system: [TimedWord]? }
    struct Speaker: Codable { var id: String; var start: Double; var end: Double }
    struct Utterance: Codable { var speaker: String; var start: Double; var end: Double; var text: String }

    var version = 1
    var engine: String
    var model: String
    /// "mic", "system" or "both"; a track not transcribed is absent from `words`.
    var channel: String
    var session: String
    var created: Date
    /// `--split-gap` the lines were cut with.
    var splitGap: Double?
    /// Canonical terms from vocab.json, or absent with `--no-vocab`.
    var vocabulary: [String]?
    var timing: Timing
    var words: Words
    var speakers: [Speaker]
    var utterances: [Utterance]

    static func words(_ words: [Word]) -> [TimedWord] {
        words.map { TimedWord(word: $0.word, start: rounded($0.startTime), end: rounded($0.endTime)) }
    }

    private static func rounded(_ t: Double) -> Double { (t * 1000).rounded() / 1000 }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) -> TranscriptFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(TranscriptFile.self, from: $0) }
    }

    /// Wall-clock time of every engine that has transcribed this session, this run first.
    static func timingSummary(dir: URL, current: String) -> [String] {
        let runs = ([current] + Engine.allCases.map(\.rawValue).filter { $0 != current })
            .compactMap { read(dir.appendingPathComponent("transcript.\($0).json")) }
        guard !runs.isEmpty else { return [] }
        let width = runs.map(\.engine.count).max() ?? 0
        return [Style.dim("  wall-clock per engine")] + runs.map { r in
            let name = r.engine.padding(toLength: width, withPad: " ", startingAt: 0)
            let detail = String(format: "%.1fs  (model load %.1fs, transcribe %.1fs)  %@ track%@",
                                r.timing.wallClockSeconds, r.timing.modelLoadSeconds, r.timing.transcribeSeconds,
                                r.channel, r.channel == "both" ? "s" : "")
            return "    \(r.engine == current ? Style.bold(name) : name)  \(detail)\(r.engine == current ? "" : Style.dim("  (earlier run)"))"
        }
    }
}
