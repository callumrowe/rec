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

    func make(config: Config?) -> any TranscriptionEngine {
        switch self {
        case .parakeet: ParakeetEngine(version: config?.model == "v3" ? .v3 : .v2)
        case .whisper: WhisperEngine(detectLanguage: config?.model == "v3")
        }
    }
}

/// FluidAudio Parakeet TDT on the whole track.
final class ParakeetEngine: TranscriptionEngine {
    let id = Engine.parakeet.rawValue
    private let version: AsrModelVersion
    private let asr = AsrManager(config: .default)

    init(version: AsrModelVersion) { self.version = version }

    var model: String { version == .v3 ? "parakeet-tdt-0.6b-v3" : "parakeet-tdt-0.6b-v2" }
    var label: String { version == .v3 ? "Parakeet v3" : "Parakeet v2" }

    func load() async throws {
        try await asr.loadModels(try await AsrModels.downloadAndLoad(version: version))
    }

    func words(in url: URL, progress: @escaping (String) -> Void) async throws -> [Word] {
        var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
        let result = try await asr.transcribe(url, decoderState: &state)
        return buildWordTimings(from: result.tokenTimings ?? [])
    }

    func unload() async { await asr.cleanup() }
}
