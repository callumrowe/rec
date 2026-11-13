import AppKit
import CoreAudio
import Darwin
import Foundation

/// Which processes are using audio right now, from Core Audio's process objects
/// (macOS 14+). Reading these needs no permission and opens no device, so it can
/// run all day without the mic indicator coming on.
enum AudioProcesses {
    struct Process {
        let pid: pid_t
        let bundleID: String?
        let name: String
        let input: Bool
        let output: Bool

        /// Bundle ID, or the executable name for daemons without one (e.g. avconferenced).
        var key: String { bundleID ?? name }
    }

    static func current() -> [Process] {
        let system = AudioDevices.systemObject
        var addr = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let pid = try? AudioDevices.get(id, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0 else { return nil }
            let input = ((try? AudioDevices.get(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0) != 0
            let output = ((try? AudioDevices.get(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            let bundleID = AudioDevices.string(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            return Process(pid: pid, bundleID: bundleID, name: processName(pid), input: input, output: output)
        }
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
    }
}

/// Decides whether a call is running from which processes hold the mic.
struct CallDetector {
    struct App {
        let prefix: String
        let name: String
    }

    /// Apps whose mic use means a call. Matched as a prefix of the bundle ID (so
    /// Electron/Chromium helper processes count) or as the executable name.
    static let callApps: [App] = [
        App(prefix: "us.zoom.", name: "Zoom"),
        App(prefix: "com.microsoft.teams", name: "Teams"),
        App(prefix: "com.tinyspeck.slackmacgap", name: "Slack"),
        App(prefix: "com.apple.FaceTime", name: "FaceTime"),
        App(prefix: "avconferenced", name: "FaceTime"),
        App(prefix: "com.cisco.webex", name: "Webex"),
        App(prefix: "com.webex.", name: "Webex"),
        App(prefix: "com.hnc.Discord", name: "Discord"),
        App(prefix: "net.whatsapp.", name: "WhatsApp"),
        App(prefix: "desktop.WhatsApp", name: "WhatsApp"),
        App(prefix: "com.skype.", name: "Skype"),
        App(prefix: "co.teamport.around", name: "Around"),
        App(prefix: "com.amazon.Amazon-Chime", name: "Chime"),
        App(prefix: "com.ringcentral.", name: "RingCentral"),
        App(prefix: "com.goto.", name: "GoTo"),
        App(prefix: "com.logmein.", name: "GoTo"),
        App(prefix: "com.bluejeans.", name: "BlueJeans"),
        App(prefix: "com.tuple.", name: "Tuple"),
        // Browsers: Meet, Whereby, Jitsi and web Teams/Zoom all run in one.
        App(prefix: "com.google.Chrome", name: "browser call"),
        App(prefix: "com.apple.Safari", name: "browser call"),
        App(prefix: "com.apple.WebKit.GPU", name: "browser call"),
        App(prefix: "company.thebrowser.", name: "browser call"),
        App(prefix: "org.mozilla.firefox", name: "browser call"),
        App(prefix: "com.microsoft.edgemac", name: "browser call"),
        App(prefix: "com.brave.Browser", name: "browser call"),
        App(prefix: "com.vivaldi.Vivaldi", name: "browser call"),
        App(prefix: "com.operasoftware.", name: "browser call"),
        App(prefix: "app.zen-browser.", name: "browser call"),
        App(prefix: "org.chromium.", name: "browser call"),
    ]

    /// Never a call, even with the speakers going too: rec itself, Siri / "Hey
    /// Siri" / dictation / Sound Recognition (which listen continuously), voice
    /// recorders and dictation apps.
    static let ignored: [String] = [
        "com.callumrowe.rec",
        "corespeechd", "com.apple.corespeech", "com.apple.siri", "com.apple.assistant", "assistantd",
        "com.apple.SpeechRecognitionCore", "com.apple.speech.", "com.apple.dictation", "DictationIM",
        "com.apple.accessibility.heard", "heard", "com.apple.VoiceMemos", "com.apple.QuickTimePlayerX",
        "com.electron.wispr-flow", "com.superduper.superwhisper", "com.goodsnooze.MacWhisper",
        "com.rogueamoeba.", "coreaudiod", "com.apple.audio.",
    ]

    var extraApps: [String] = []
    var extraIgnored: [String] = []
    var ownPIDs: Set<pid_t> = []

    func isIgnored(_ p: AudioProcesses.Process) -> Bool {
        ownPIDs.contains(p.pid) || (Self.ignored + extraIgnored).contains { matches(p, $0) }
    }

    /// The call app's display name if a call is running, else nil.
    /// A known call app (or a browser) holding the mic is a call. Any other app
    /// holding the mic counts only while something is also playing audio, which
    /// is the "mic and system audio at once" signal without listening to either.
    func detect(_ processes: [AudioProcesses.Process]) -> String? {
        let candidates = processes.filter { !isIgnored($0) }
        let usingMic = candidates.filter(\.input)
        for p in usingMic {
            if let app = Self.callApps.first(where: { matches(p, $0.prefix) }) {
                return app.name == "browser call" ? "\(displayName(p)) call" : app.name
            }
            if extraApps.contains(where: { matches(p, $0) }) { return displayName(p) }
        }
        if let p = usingMic.first, candidates.contains(where: \.output) {
            return displayName(p)
        }
        return nil
    }

    private func matches(_ p: AudioProcesses.Process, _ pattern: String) -> Bool {
        (p.bundleID?.hasPrefix(pattern) ?? false) || p.name == pattern
    }

    /// "Google Chrome" rather than "Google Chrome Helper", via the owning app.
    func displayName(_ p: AudioProcesses.Process) -> String {
        // Safari's (and every WebKit app's) audio runs in a shared GPU process.
        if p.bundleID?.hasPrefix("com.apple.WebKit") == true { return "browser" }
        if let app = NSRunningApplication(processIdentifier: p.pid), let name = app.localizedName {
            return name.replacingOccurrences(of: #" Helper.*$"#, with: "", options: .regularExpression)
        }
        if let bid = p.bundleID?.replacingOccurrences(of: #"\.helper.*$"#, with: "", options: [.regularExpression, .caseInsensitive]),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
           let name = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String {
            return name
        }
        return p.name
    }
}
