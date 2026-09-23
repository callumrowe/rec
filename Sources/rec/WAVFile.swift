import Foundation

/// 16-bit PCM mono WAV writer. The header is rewritten periodically so a crash
/// leaves a playable file.
final class WAVWriter {
    static let headerSize: UInt64 = 44

    let sampleRate: Int
    private let handle: FileHandle
    private(set) var frames: Int64 = 0

    init(url: URL, sampleRate: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.sampleRate = sampleRate
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, frames: 0))
    }

    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let s = max(-1, min(1, samples[i]))
            pcm[i] = Int16((s * 32767).rounded())
        }
        try pcm.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        frames += Int64(samples.count)
    }

    func appendSilence(_ count: Int64) throws {
        var remaining = count
        let chunk = Data(count: Int(min(count, Int64(sampleRate))) * 2)
        while remaining > 0 {
            let n = min(remaining, Int64(chunk.count / 2))
            try handle.write(contentsOf: n == Int64(chunk.count / 2) ? chunk : chunk.prefix(Int(n) * 2))
            remaining -= n
        }
        frames += count
    }

    func truncate(toFrames n: Int64) throws {
        try handle.truncate(atOffset: Self.headerSize + UInt64(n) * 2)
        frames = n
        try handle.seekToEnd()
    }

    func updateHeader() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, frames: frames))
        try handle.seek(toOffset: end)
    }

    func close() throws {
        try updateHeader()
        try handle.synchronize()
        try handle.close()
    }

    static func header(sampleRate: Int, frames: Int64) -> Data {
        let dataBytes = UInt32(clamping: frames * 2)
        var d = Data()
        func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        tag("RIFF"); u32(36 &+ dataBytes); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        tag("data"); u32(dataBytes)
        return d
    }
}

/// Minimal reader for the verify command: 16-bit PCM, any channel count (first channel used).
struct WAVData {
    let sampleRate: Int
    let samples: [Float]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        func u32(_ o: Int) -> UInt32 { data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u16(_ o: Int) -> UInt16 { data.subdata(in: o..<o + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        func tag(_ o: Int) -> String { String(decoding: data.subdata(in: o..<o + 4), as: UTF8.self) }
        guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw CocoaError(.fileReadCorruptFile) }

        var offset = 12
        var rate = 0, channels = 1, bits = 0
        var pcm: Range<Int>?
        while offset + 8 <= data.count {
            let id = tag(offset)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                channels = Int(u16(body + 2)); rate = Int(u32(body + 4)); bits = Int(u16(body + 14))
            } else if id == "data" {
                pcm = body..<min(body + size, data.count)
            }
            offset = body + size + (size & 1)
        }
        guard let pcm, bits == 16, rate > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let frameCount = pcm.count / (2 * channels)
        var out = [Float](repeating: 0, count: frameCount)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: pcm.lowerBound)
            for i in 0..<frameCount {
                let v = base.loadUnaligned(fromByteOffset: i * 2 * channels, as: Int16.self)
                out[i] = Float(Int16(littleEndian: v)) / 32768
            }
        }
        sampleRate = rate
        samples = out
    }
}
