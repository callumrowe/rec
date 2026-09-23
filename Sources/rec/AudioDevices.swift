import CoreAudio
import IOKit
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status) '\(fourCC(UInt32(bitPattern: status)))')" }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

func fourCC(_ v: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
    return String(v)
}

/// Seconds between two mach host times.
func hostSeconds(from start: UInt64, to end: UInt64) -> Double {
    if end >= start { return Double(AudioConvertHostTimeToNanos(end - start)) / 1e9 }
    return -Double(AudioConvertHostTimeToNanos(start - end)) / 1e9
}

enum AudioDevices {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "get '\(fourCC(selector))'")
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func all() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uid(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        ((try? get(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0) != 0
    }

    static func channels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Resolves a UID to a live device, or nil if it isn't currently present.
    static func device(uid: String) -> AudioObjectID? {
        all().first { self.uid($0) == uid && isAlive($0) }
    }

    private static func builtIn(scope: AudioObjectPropertyScope) -> String? {
        all().first { dev in
            let transport = (try? get(dev, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
            return transport == kAudioDeviceTransportTypeBuiltIn && channels(dev, scope: scope) > 0
        }.flatMap(uid)
    }

    static func builtInInputUID() -> String? { builtIn(scope: kAudioObjectPropertyScopeInput) }

    struct Input {
        let uid: String
        let name: String
        let transport: UInt32

        var kind: String {
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: "built-in"
            case kAudioDeviceTransportTypeUSB: "USB"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeAutoAggregate: "virtual"
            case kAudioDeviceTransportTypeContinuityCaptureWired,
                 kAudioDeviceTransportTypeContinuityCaptureWireless: "iPhone"
            default: "other"
            }
        }
    }

    /// Live devices with at least one input channel, excluding private aggregates.
    static func inputs() -> [Input] {
        all().compactMap { dev in
            guard isAlive(dev), channels(dev, scope: kAudioObjectPropertyScopeInput) > 0,
                  let uid = uid(dev), !uid.hasPrefix("rec-system-tap") else { return nil }
            let transport = (try? get(dev, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
            return Input(uid: uid, name: name(dev) ?? uid, transport: transport)
        }
    }

    static func defaultInputUID() -> String? {
        guard let dev = try? get(systemObject, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0)),
              dev != kAudioObjectUnknown else { return nil }
        return uid(dev)
    }

    /// Matches an exact UID, else a case-insensitive substring of the device name.
    static func resolveInput(_ query: String) -> (input: Input?, error: String?) {
        let inputs = inputs()
        if let exact = inputs.first(where: { $0.uid == query }) { return (exact, nil) }
        let matches = inputs.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch matches.count {
        case 1: return (matches[0], nil)
        case 0: return (nil, "no input device matches \"\(query)\"; see `rec devices`")
        default: return (nil, "\"\(query)\" matches several devices (\(matches.map(\.name).joined(separator: ", "))); use the UID from `rec devices`")
        }
    }
    static func builtInOutputUID() -> String? { builtIn(scope: kAudioObjectPropertyScopeOutput) }

    static func defaultOutputUID() -> String? {
        guard let dev = try? get(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)),
              dev != kAudioObjectUnknown else { return nil }
        return uid(dev)
    }
}

/// True when a MacBook's lid is closed (the built-in mic is then hardware-muted
/// and delivers digital silence), nil on Macs without a lid.
func isLidClosed() -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return value?.takeRetainedValue() as? Bool
}
