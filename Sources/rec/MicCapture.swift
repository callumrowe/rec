import AVFoundation
import CoreAudio
import Foundation

/// Records one specific input device, pinned by UID. Never follows the system
/// default input: if the device goes away, capture stops (the writer pads the
/// gap with silence) and resumes when the same UID comes back.
final class MicCapture {
    let uid: String
    private let writer: TrackWriter
    private let log: (String) -> Void
    private var engine: AVAudioEngine?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var observer: NSObjectProtocol?
    private var lostAt: Date?
    private var lastAttempt = Date.distantPast
    private var lastFailure: String?

    var isRunning: Bool { engine != nil }

    init(uid: String, writer: TrackWriter, log: @escaping (String) -> Void) {
        self.uid = uid
        self.writer = writer
        self.log = log
    }

    /// Main thread only.
    func start() {
        lastAttempt = Date()
        switch startEngine() {
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

    /// Main thread, ~1 Hz. Detects the device vanishing or being swapped out, and reconnects.
    func poll() {
        if let engine {
            let alive = AudioDevices.isAlive(deviceID) && AudioDevices.device(uid: uid) == deviceID
            if !alive { stopEngine(); markLost("device disappeared") }
            else if currentDevice(of: engine) != deviceID { stopEngine(); markLost("engine switched away from pinned device") }
            else if !engine.isRunning { stopEngine(); markLost("engine stopped") }
        }
        // Retry quickly when the device is present, otherwise just watch for it.
        if engine == nil, AudioDevices.device(uid: uid) != nil, Date().timeIntervalSince(lastAttempt) >= 2 {
            start()
        }
    }

    func stop() {
        stopEngine()
    }

    private enum StartResult { case success, failure(String) }

    private func startEngine() -> StartResult {
        guard let device = AudioDevices.device(uid: uid) else { return .failure("device not present") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { return .failure("no input audio unit") }
        var dev = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { return .failure("could not pin device (OSStatus \(status))") }
        // After switching devices the node's output format can still describe the
        // previous (default) device; a tap in that format never receives buffers.
        // Use the pinned device's hardware rate and channel count instead.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
        else { return .failure("device reports no input format") }

        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            writer.queue.sync { writer.process(buffer, hostTime: host) }
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            guard let self, self.engine === engine else { return }
            // AVAudioEngine posts this spuriously right after starting on a
            // non-default device; only rebuild if it actually stopped or moved.
            if engine.isRunning, self.currentDevice(of: engine) == device { return }
            self.stopEngine()
            self.log("mic: audio configuration changed, reattaching to \(self.uid)")
            self.start()
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            return .failure("engine start failed: \(error.localizedDescription)")
        }
        guard currentDevice(of: engine) == device else {
            engine.stop()
            input.removeTap(onBus: 0)
            return .failure("engine did not stay on pinned device")
        }
        self.engine = engine
        deviceID = device
        return .success
    }

    private func stopEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func currentDevice(of engine: AVAudioEngine) -> AudioObjectID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, &size) == noErr else { return nil }
        return dev
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
