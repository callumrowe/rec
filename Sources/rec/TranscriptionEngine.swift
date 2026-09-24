import FluidAudio
import Foundation

/// A timed word on the session timeline (seconds from the start of the track).
typealias Word = WordTiming  // FluidAudio's; this file doesn't import WhisperKit, whose WordTiming would clash

/// Speech-to-text for one track. Everything after `words(in:)` (echo removal,
/// diarization, turns, the note) is shared, so engines only turn audio into words.
protocol TranscriptionEngine: AnyObject {
    /// `--engine` value, and the `<id>` in `transcript.<id>.json`.
    var id: String { get }
    /// Model identifier recorded in the transcript and the note.
    var model: String { get }
    /// Shown while loading, e.g. "Parakeet v2".
    var label: String { get }
    func load() async throws
    /// Words with timestamps on the track's own timeline.
    func words(in url: URL, progress: @escaping (String) -> Void) async throws -> [Word]
    func unload() async
}

enum Engine: String, CaseIterable {
    case parakeet, whisper

    /// `vocabulary` turns on Parakeet's keyword boosting; Whisper has none, so it only gets the alias pass.
    func make(config: Config?, vocabulary: Vocabulary?) -> any TranscriptionEngine {
        switch self {
        case .parakeet: ParakeetEngine(version: config?.model == "v3" ? .v3 : .v2, vocabulary: vocabulary)
        case .whisper: WhisperEngine(detectLanguage: config?.model == "v3")
        }
    }
}

/// FluidAudio Parakeet TDT on the whole track. With a vocabulary, the result
/// is rescored against a CTC keyword spotter (parakeet-ctc-110m, downloaded on
/// first use): the same `VocabularyBoostingSession` FluidAudio's sliding-window
/// and unified managers run, applied here to the batch manager's output so the
/// TDT v2/v3 decode itself is unchanged.
final class ParakeetEngine: TranscriptionEngine {
    let id = Engine.parakeet.rawValue
    private let version: AsrModelVersion
    private let vocabulary: Vocabulary?
    private let asr = AsrManager(config: .default)
    private var boosting: VocabularyBoostingSession?

    init(version: AsrModelVersion, vocabulary: Vocabulary?) {
        self.version = version
        self.vocabulary = vocabulary
    }

    var model: String { version == .v3 ? "parakeet-tdt-0.6b-v3" : "parakeet-tdt-0.6b-v2" }
    var label: String { version == .v3 ? "Parakeet v3" : "Parakeet v2" }

    func load() async throws {
        try await asr.loadModels(try await AsrModels.downloadAndLoad(version: version))
        if let vocabulary, !vocabulary.terms.isEmpty {
            boosting = try await VocabularyBoostingSession(
                vocabulary: vocabulary.context, ctcModels: try await CtcModels.downloadAndLoad(),
                config: .init(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false))
        }
    }

    func words(in url: URL, progress: @escaping (String) -> Void) async throws -> [Word] {
        var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
        let result = try await asr.transcribe(url, decoderState: &state)
        let timings = result.tokenTimings ?? []
        let words = Self.words(from: timings)
        guard let boosting else { return words }
        progress("vocabulary")
        let samples = try AudioConverter().resampleAudioFile(url)
        guard let rescored = await boosting.rescore(text: result.text, tokenTimings: timings, audioSamples: samples),
              rescored.wasModified else { return words }
        for r in rescored.replacements where r.shouldReplace {
            fputs("vocabulary: \(url.lastPathComponent) \"\(r.originalWord)\" → \"\(r.replacementWord ?? "")\" (\(r.reason))\n", stderr)
        }
        return Self.retime(rescored.text, onto: words)
    }

    /// Longest a TDT token can last: 4 encoder frames of 80 ms.
    private static let maxTokenSeconds = 0.32

    /// FluidAudio's `buildWordTimings`, but with word ends that stop at the
    /// speech, so pauses show. A token without a TDT duration is given until
    /// the next token starts, and a sentence's "." is emitted when the next
    /// speech begins, so "weird." would otherwise run through the pause after it.
    static func words(from timings: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        for t in timings where !t.token.isEmpty && t.token != "<blank>" && t.token != "<pad>" {
            let piece = stripWordBoundaryPrefix(t.token)
            let spoken = piece.contains { $0.isLetter || $0.isNumber }
            let end = min(t.endTime, t.startTime + maxTokenSeconds)
            if let last = words.last, !isWordBoundary(t.token) {
                words[words.count - 1] = Word(word: last.word + piece, startTime: last.startTime,
                                              endTime: spoken ? end : last.endTime)
            } else if !piece.isEmpty {
                words.append(Word(word: piece, startTime: t.startTime, endTime: end))
            }
        }
        return words
    }

    /// The rescorer hands back text only. Its words are ours with some replaced,
    /// so line the two up and give each replacement the time of what it replaced.
    static func retime(_ text: String, onto words: [Word]) -> [Word] {
        func key(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let new = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let diff = new.map(key).difference(from: words.map { key($0.word) })
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Word] = []
        var i = 0, j = 0
        while i < words.count || j < new.count {
            if i < words.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                out.append(words[i])  // unchanged: keep our spelling and punctuation
                i += 1; j += 1
                continue
            }
            var old: [Word] = []
            while i < words.count, removed.contains(i) { old.append(words[i]); i += 1 }
            var replacement: [String] = []
            while j < new.count, inserted.contains(j) { replacement.append(new[j]); j += 1 }
            if old.isEmpty && replacement.isEmpty { break }  // unreachable for a well-formed diff
            guard !replacement.isEmpty else { continue }
            let start = old.first?.startTime ?? out.last?.endTime ?? words.first?.startTime ?? 0
            let end = old.last?.endTime ?? start
            // Keep sentence punctuation, which the turn splitting relies on.
            if let tail = old.last?.word.last, ".?!,".contains(tail), replacement[replacement.count - 1].last != tail {
                replacement[replacement.count - 1].append(tail)
            }
            let step = (end - start) / Double(replacement.count)
            for (k, w) in replacement.enumerated() {
                out.append(Word(word: w, startTime: start + step * Double(k), endTime: start + step * Double(k + 1)))
            }
        }
        return out
    }

    func unload() async { await asr.cleanup() }
}
