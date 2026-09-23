import AVFoundation
import Foundation

/// Converts incoming buffers to 16 kHz mono and places them on the shared session
/// timeline. Every buffer's host timestamp is mapped to a frame position relative
/// to the session start (t0); if the file is behind that position the gap is
/// filled with silence, if it is ahead the overlapping samples are dropped. Both
/// tracks use the same t0 and the same end time, so they stay aligned and end up
/// the same length.
final class TrackWriter {
    static let sampleRate = 16_000.0

    struct Meter {
        /// RMS of samples received since the last call, nil if none arrived.
        let rms: Double?
        /// Seconds since the last buffer arrived (infinity if never).
        let secondsSinceLastBuffer: Double
    }

    let name: String
    /// All `process` calls must happen on this queue.
    let queue: DispatchQueue

    private let wav: WAVWriter
    private let t0: UInt64
    private let log: (String) -> Void
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var closed = false
    private var writeFailed = false

    /// Drift below this is left alone (converter latency, timestamp jitter).
    private let tolerance: Int64 = 320        // 20 ms
    /// Gaps at least this long are reported as events.
    private let reportableGap: Int64 = 1_600  // 100 ms
    private(set) var smallCorrections = 0

    private let meterLock = NSLock()
    private var sumSquares = 0.0
    private var meterCount = 0
    private var lastBufferHost: UInt64 = 0

    init(name: String, url: URL, t0: UInt64, log: @escaping (String) -> Void) throws {
        self.name = name
        self.t0 = t0
        self.log = log
        self.queue = DispatchQueue(label: "rec.track.\(name)", qos: .userInitiated)
        self.wav = try WAVWriter(url: url, sampleRate: Int(Self.sampleRate))
    }

    func framePosition(hostTime: UInt64) -> Int64 {
        Int64((hostSeconds(from: t0, to: hostTime) * Self.sampleRate).rounded())
    }

    /// `hostTime` is the host time of the first frame in `buffer`.
    func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed, buffer.frameLength > 0 else { return }
        meterLock.withLock { lastBufferHost = mach_absolute_time() }

        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.downmix = true
            if converter == nil { log("\(name): cannot convert from \(buffer.format)"); return }
        }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter!.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { log("\(name): conversion failed: \(error?.localizedDescription ?? "unknown")"); return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        let samples = UnsafeBufferPointer(start: out.floatChannelData![0], count: n)

        var sum = 0.0
        for s in samples { sum += Double(s * s) }
        meterLock.withLock { sumSquares += sum; meterCount += n }

        let written = wav.frames
        let delta = framePosition(hostTime: hostTime) - written
        var skip = 0
        do {
            if delta > tolerance {
                if delta >= reportableGap {
                    log(String(format: "%@: %.2fs gap at %@, padded with silence", name,
                               Double(delta) / Self.sampleRate, clock(Double(written) / Self.sampleRate)))
                } else {
                    smallCorrections += 1
                }
                try wav.appendSilence(delta)
            } else if delta < -tolerance {
                skip = min(n, Int(-delta))
                if written > 0 { smallCorrections += 1 }  // at written == 0 it's just audio from before t0
            }
            if skip < n { try wav.append(UnsafeBufferPointer(rebasing: samples[skip...])) }
        } catch {
            if !writeFailed { log("\(name): write failed: \(error.localizedDescription)") }
            writeFailed = true
        }
    }

    func takeMeter() -> Meter {
        meterLock.withLock {
            let rms = meterCount > 0 ? (sumSquares / Double(meterCount)).squareRoot() : nil
            sumSquares = 0
            meterCount = 0
            let age = lastBufferHost == 0 ? .infinity : hostSeconds(from: lastBufferHost, to: mach_absolute_time())
            return Meter(rms: rms, secondsSinceLastBuffer: age)
        }
    }

    func flushHeader() {
        queue.async { [self] in
            guard !closed else { return }
            try? wav.updateHeader()
        }
    }

    /// Pads or trims to exactly `frames` and closes the file. Returns (frames written by capture, frames after finalize).
    @discardableResult
    func finalize(frames: Int64) -> (captured: Int64, final: Int64) {
        queue.sync {
            let captured = wav.frames
            closed = true
            do {
                if captured < frames { try wav.appendSilence(frames - captured) }
                else if captured > frames { try wav.truncate(toFrames: frames) }
                try wav.close()
            } catch {
                log("\(name): finalize failed: \(error.localizedDescription)")
            }
            return (captured, wav.frames)
        }
    }
}

func clock(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
