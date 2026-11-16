import AVFoundation
import CoreAudio
import Foundation

/// Records one specific input device, pinned by UID. Never follows the system
/// default input: if the device goes away, capture stops (the writer pads the
/// gap with silence) and resumes when the same UID comes back.
///
/// Uses a plain HAL IO proc on the device rather than AVAudioEngine. With a
/// process tap running (SystemTap), macOS will not start a new input IO proc:
/// AudioDeviceStart blocks forever, and AVAudioEngine additionally stops itself
/// when the tap's aggregate device appears, then hangs trying to restart. So the
/// mic must start before the tap, and any later restart goes through
/// `whileSystemPaused`, which stops the tap around it.
final class MicCapture {
    let uid: String
    private let writer: TrackWriter
    private let log: (String) -> Void
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// The device's sample rate when the IO proc started; a change means reopen.
    private var sampleRate = 0.0
    private var lostAt: Date?
    private var lastAttempt = Date.distantPast
    private var lastFailure: String?
    private var startedAt = Date.distantPast
    /// Host time of the last IO callback; written on writer.queue, read on main.
    private let lastBufferLock = NSLock()
    private var lastBufferHost: UInt64 = 0

    /// Runs a (re)start with the system tap stopped; set by Recorder.
    var whileSystemPaused: (() -> Void) -> Void = { $0() }

    var isRunning: Bool { procID != nil }

    /// How much quieter the built-in mic's raw capsules are than its normal 1-channel
    /// output (measured on a MacBook Pro: -39 dB vs -67 dB for the same sound).
    static let rawArrayGainDB = 28.0

    init(uid: String, writer: TrackWriter, log: @escaping (String) -> Void) {
        self.uid = uid
        self.writer = writer
        self.log = log
    }

    deinit { stopIO() }

    /// Main thread only. The first start must happen before the system tap starts.
    func start() {
        lastAttempt = Date()
        var result = StartResult.failure("not started")
        whileSystemPaused { result = startIO() }
        switch result {
        case .success:
            if let lostAt {
                log(String(format: "mic: %@ back after %.1fs, resumed", uid, Date().timeIntervalSince(lostAt)))
            }
            lostAt = nil
            lastFailure = nil
        case .failure(let reason):
            markLost(reason)
        }
    }

    /// Main thread, ~1 Hz. Detects the device vanishing or going quiet at the IO
    /// level (no callbacks at all, not just silence), and reconnects.
    func poll() {
        if procID != nil {
            let alive = AudioDevices.isAlive(deviceID) && AudioDevices.device(uid: uid) == deviceID
            if !alive {
                stopIO(); markLost("device disappeared")
            } else if Date().timeIntervalSince(startedAt) > 3, secondsSinceLastCallback() > 3 {
                stopIO(); markLost("device stopped delivering audio")
            } else if let rate = Self.inputFormat(deviceID)?.mSampleRate, rate != sampleRate {
                // Buffers would be resampled at the wrong rate: reopen at the new one.
                stopIO(); markLost(String(format: "sample rate changed to %.0f Hz", rate))
            }
        }
        // Retry when the device is present, otherwise just watch for it.
        if procID == nil, AudioDevices.device(uid: uid) != nil, Date().timeIntervalSince(lastAttempt) >= 2 {
            start()
        }
    }

    func stop() {
        stopIO()
    }

    private enum StartResult { case success, failure(String) }

    private func startIO() -> StartResult {
        guard let device = AudioDevices.device(uid: uid) else { return .failure("device not present") }
        guard let asbd = Self.inputFormat(device) else { return .failure("device reports no input format") }
        // The HAL hands IO procs native Float32; anything else we can't read.
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 1, interleaved: false)
        else { return .failure("device delivers an unsupported sample format") }

        // The channel count is read from every buffer, not trusted from the start:
        // when a call app turns on Apple's voice processing (Safari/WebRTC, FaceTime
        // and others), the built-in mic switches from 1 channel to its raw 3-mic
        // array, possibly mid-recording. (Building an AVAudioFormat from the 3-channel
        // description returns nil, which left the mic unrecorded for a whole Safari call.)
        // The raw array skips the mic's own gain and beamforming and comes in ~28 dB
        // quieter, so average the capsules and make up the gain. Any other
        // multichannel device (an audio interface): record its first channel.
        let builtIn = (try? AudioDevices.get(device, kAudioDevicePropertyTransportType, initial: UInt32(0))) == kAudioDeviceTransportTypeBuiltIn
        let writer = self.writer
        let lock = lastBufferLock
        let log = self.log
        let uid = self.uid
        var lastChannels = Int(asbd.mChannelsPerFrame)
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, writer.queue) { [weak self] _, inputData, inputTime, _, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let ts = inputTime.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : mach_absolute_time()
            lock.withLock { self?.lastBufferHost = mach_absolute_time() }
            guard let first = input.first, let data = first.mData, first.mNumberChannels > 0 else { return }
            // Interleaved: one buffer of N channels. Non-interleaved: N buffers of 1.
            let stride = Int(first.mNumberChannels)
            let channels = stride > 1 ? stride : input.count
            let rawArray = builtIn && stride > 1
            if channels != lastChannels {
                log("mic: \(uid) now delivers \(channels) channel\(channels == 1 ? "" : "s") (another app changed its mode); "
                    + (rawArray ? "mixing them and boosting \(Int(Self.rawArrayGainDB)) dB" : "recording the first"))
                lastChannels = channels
            }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)) else { return }
            let src = data.assumingMemoryBound(to: Float.self)
            let dst = pcm.floatChannelData![0]
            if stride == 1 {
                dst.update(from: src, count: frames)
            } else if rawArray {
                let gain = Float(pow(10, Self.rawArrayGainDB / 20)) / Float(stride)
                for i in 0..<frames {
                    var sum: Float = 0
                    for k in 0..<stride { sum += src[i * stride + k] }
                    dst[i] = max(-1, min(1, sum * gain))
                }
            } else {
                for i in 0..<frames { dst[i] = src[i * stride] }
            }
            pcm.frameLength = AVAudioFrameCount(frames)
            writer.process(pcm, hostTime: host)
        }
        guard status == noErr, let proc else {
            return .failure("could not open device (OSStatus \(status))")
        }
        let started = AudioDeviceStart(device, proc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            return .failure("could not start device (OSStatus \(started))")
        }
        procID = proc
        deviceID = device
        sampleRate = asbd.mSampleRate
        startedAt = Date()
        lastBufferLock.withLock { lastBufferHost = mach_absolute_time() }
        return .success
    }

    /// The device's input stream format (what an IO proc receives), or nil if it has none.
    static func inputFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
        guard let asbd = try? AudioDevices.get(device, kAudioDevicePropertyStreamFormat, initial: AudioStreamBasicDescription(),
                                               scope: kAudioObjectPropertyScopeInput),
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        return asbd
    }

    private func stopIO() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        // Let any in-flight IO block finish.
        writer.queue.sync {}
    }

    private func secondsSinceLastCallback() -> Double {
        let last = lastBufferLock.withLock { lastBufferHost }
        return hostSeconds(from: last, to: mach_absolute_time())
    }

    private func markLost(_ reason: String) {
        if lostAt == nil {
            lostAt = Date()
            log("mic: \(uid) unavailable (\(reason)); system audio keeps recording, mic gap will be silence")
        } else if reason != lastFailure {
            log("mic: still unavailable (\(reason))")
        }
        lastFailure = reason
    }
}
