import FluidAudio
import Foundation
import WhisperKit

/// WhisperKit large-v3-turbo, fed only the speech regions FluidAudio's Silero
/// VAD finds. Whisper invents text over silence ("Thank you.", "Subtitles by…"),
/// so silence never reaches it; each region is transcribed on its own and its
/// words are shifted back onto the track's timeline.
final class WhisperEngine: TranscriptionEngine {
    let id = Engine.whisper.rawValue
    let model = "whisper-large-v3-turbo"
    let label = "Whisper large-v3-turbo"
    /// The large-v3-turbo folder in argmaxinc/whisperkit-coreml (a glob, so no `_turbo_632MB`).
    private static let variant = "large-v3-v20240930_turbo"
    /// Regions per WhisperKit call; it decodes that many at once.
    private static let batch = 16

    private let detectLanguage: Bool
    private var whisper: WhisperKit?
    private var vad: VadManager?

    init(detectLanguage: Bool) { self.detectLanguage = detectLanguage }

    func load() async throws {
        // Downloads to ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml on first run.
        whisper = try await WhisperKit(WhisperKitConfig(
            model: Self.variant, verbose: false, logLevel: .none, prewarm: false, load: true, download: true))
        vad = try await VadManager()
    }

    func words(in url: URL, progress: @escaping (String) -> Void) async throws -> [Word] {
        guard let whisper, let vad else { throw TranscribeError("Whisper models not loaded") }
        let samples = try AudioConverter().resampleAudioFile(url)
        let rate = Double(VadManager.sampleRate)
        // Whisper's window is 30 s; keep regions just under it so none gets chunked.
        let regions = try await vad.segmentSpeech(samples, config: VadSegmentationConfig(maxSpeechDuration: 28))
        fputs("vad: \(url.lastPathComponent) \(regions.count) speech regions, "
              + String(format: "%.1fs of %.1fs\n", regions.reduce(0) { $0 + $1.duration }, Double(samples.count) / rate), stderr)

        let options = DecodingOptions(
            language: detectLanguage ? nil : "en", detectLanguage: detectLanguage,
            skipSpecialTokens: true, wordTimestamps: true)
        var words: [Word] = []
        for start in stride(from: 0, to: regions.count, by: Self.batch) {
            progress("\(start)/\(regions.count) speech regions")
            let chunk = regions[start..<min(start + Self.batch, regions.count)]
            let audio = chunk.map { r -> [Float] in
                let lo = max(0, min(r.startSample(sampleRate: Int(rate)), samples.count))
                let hi = max(lo, min(r.endSample(sampleRate: Int(rate)), samples.count))
                return Array(samples[lo..<hi])
            }
            let results = await whisper.transcribeWithResults(audioArrays: audio, decodeOptions: options)
            for (region, result) in zip(chunk, results) {
                let length = region.endTime - region.startTime
                for segment in try result.get().flatMap(\.segments) {
                    for w in segment.words ?? [] {
                        let text = w.word.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty, !text.hasPrefix("<|") else { continue }
                        // Region-relative → track time. Clamp: Whisper's last timestamp can overshoot the audio it was given.
                        let s = region.startTime + min(max(0, Double(w.start)), length)
                        let e = region.startTime + min(max(Double(w.start), Double(w.end)), length)
                        words.append(Word(word: text, startTime: s, endTime: e))
                    }
                }
            }
        }
        return words
    }

    func unload() async {
        await whisper?.unloadModels()
        whisper = nil
        vad = nil
    }
}
