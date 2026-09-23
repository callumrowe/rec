import AVFoundation
import CoreAudio
import Foundation

/// Global Core Audio process tap (all processes, mixed to mono) wrapped in a
/// private aggregate device.
final class SystemTap {
    private let writer: TrackWriter
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapBuffers: UnsafeMutableAudioBufferListPointer?
    private(set) var clockDeviceUID: String?

    var isRunning: Bool { procID != nil }

    init(writer: TrackWriter) {
        self.writer = writer
    }

    deinit { stop() }

    func start() throws {
        do { try startUnchecked() } catch { stop(); throw error }
    }

    private func startUnchecked() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "rec system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        var format = try AudioDevices.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())

        // The aggregate needs a clock. Prefer the built-in speakers: they never
        // disappear, unlike AirPods or a USB headset the call might be using.
        guard let clockUID = AudioDevices.builtInOutputUID() ?? AudioDevices.defaultOutputUID() else {
            throw CoreAudioError(what: "finding an output device to clock the tap", status: -1)
        }
        clockDeviceUID = clockUID
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "rec-system-tap",
            kAudioAggregateDeviceUIDKey: "rec-system-tap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        // With drift compensation the tap is delivered at the aggregate's rate.
        if let rate = try? AudioDevices.get(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)), rate > 0 {
            format.mSampleRate = rate
        }
        guard let avFormat = AVAudioFormat(streamDescription: &format) else {
            throw CoreAudioError(what: "tap format", status: -1)
        }
        let tapBufferCount = avFormat.isInterleaved ? 1 : Int(avFormat.channelCount)
        let buffers = AudioBufferList.allocate(maximumBuffers: tapBufferCount)
        tapBuffers = buffers

        let writer = self.writer
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, writer.queue) { _, inputData, inputTime, _, _ in
            // The aggregate's input is [clock device inputs…, tap]. The built-in
            // speakers have no inputs, but take the trailing buffers to be safe.
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard input.count >= tapBufferCount else { return }
            for i in 0..<tapBufferCount { buffers[i] = input[input.count - tapBufferCount + i] }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: buffers.unsafePointer, deallocator: nil) else { return }
            let ts = inputTime.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : mach_absolute_time()
            writer.process(pcm, hostTime: host)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        // Let any in-flight IO block finish before freeing its buffer list.
        writer.queue.sync {}
        if let tapBuffers { free(tapBuffers.unsafeMutablePointer) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapBuffers = nil
    }
}
