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
    private var buffers: UnsafeMutableAudioBufferListPointer?
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
        guard var asbd = try? AudioDevices.get(device, kAudioDevicePropertyStreamFormat, initial: AudioStreamBasicDescription(),
                                               scope: kAudioObjectPropertyScopeInput),
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return .failure("device reports no input format") }

        // A non-interleaved stream arrives as one buffer per channel; take the first stream's.
        let count = format.isInterleaved ? 1 : Int(format.channelCount)
        let list = AudioBufferList.allocate(maximumBuffers: count)
        let writer = self.writer
        let lock = lastBufferLock
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, writer.queue) { [weak self] _, inputData, inputTime, _, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let ts = inputTime.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : mach_absolute_time()
            lock.withLock { self?.lastBufferHost = mach_absolute_time() }
            guard input.count >= count else { return }
            for i in 0..<count { list[i] = input[i] }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil) else { return }
            writer.process(pcm, hostTime: host)
        }
        guard status == noErr, let proc else {
            free(list.unsafeMutablePointer)
            return .failure("could not open device (OSStatus \(status))")
        }
        let started = AudioDeviceStart(device, proc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            free(list.unsafeMutablePointer)
            return .failure("could not start device (OSStatus \(started))")
        }
        procID = proc
        deviceID = device
        buffers = list
        startedAt = Date()
        lastBufferLock.withLock { lastBufferHost = mach_absolute_time() }
        return .success
    }

    private func stopIO() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        // Let any in-flight IO block finish before freeing its buffer list.
        writer.queue.sync {}
        if let buffers { free(buffers.unsafeMutablePointer) }
        buffers = nil
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
