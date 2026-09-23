import Foundation

/// `rec verify [DIR]`: checks the done criteria on a finished session. Equal
/// length, both tracks non-silent, and sync. Sync is measured by
/// cross-correlating 10 ms energy envelopes of system.wav against mic.wav: when
/// the call plays through the speakers the mic hears it a few ms later, and that
/// lag should stay constant for the whole recording. With headphones the mic
/// can't hear the call and sync can't be measured this way.
enum Verify {
    static func run(_ args: [String]) -> Never {
        let dir: URL
        if let path = args.first {
            dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let latest = latestSession() {
            dir = latest
        } else {
            fail("no sessions in \(Paths.recordingsRoot.path)")
        }
        print("\(Style.dim("session"))  \(Style.path(dir.path))")
        print("")
        let mic: WAVData, system: WAVData
        do {
            mic = try WAVData(url: dir.appendingPathComponent("mic.wav"))
            system = try WAVData(url: dir.appendingPathComponent("system.wav"))
        } catch {
            fail("cannot read WAVs: \(error.localizedDescription)")
        }

        func row(_ pass: Bool?, _ label: String, _ detail: String) {
            let mark = pass.map { $0 ? Style.ok : Style.bad } ?? Style.warn
            print("\(mark) \(Style.bold(label.padding(toLength: 7, withPad: " ", startingAt: 0))) \(detail)")
        }
        let sep = Style.faint(" · ")

        var ok = true
        let rate = Double(mic.sampleRate)
        let sameLength = mic.samples.count == system.samples.count
        if sameLength {
            row(true, "length", "\(clock(Double(mic.samples.count) / rate))\(sep)\(Style.dim("\(mic.samples.count) frames on both tracks"))")
        } else {
            row(false, "length", String(format: "mic %d frames (%@), system %d frames (%@): tracks differ",
                                        mic.samples.count, clock(Double(mic.samples.count) / rate),
                                        system.samples.count, clock(Double(system.samples.count) / rate)))
        }
        ok = ok && sameLength && mic.sampleRate == 16_000 && system.sampleRate == 16_000

        for (name, track) in [("mic", mic), ("system", system)] {
            let s = stats(track.samples, rate: rate)
            let good = s.silentFraction < 0.9
            let silent = String(format: "%.0f%% silent", s.silentFraction * 100)
            row(good, name, String(format: "rms %.1f dBFS", s.rmsDB) + sep + String(format: "peak %.1f dBFS", s.peakDB)
                + sep + (good ? Style.dim(silent) : Style.fg(silent, Style.red)))
            ok = ok && good
        }

        let lags = syncLags(system: system.samples, mic: mic.samples, rate: rate)
        let trusted = lags.filter { $0.correlation >= 0.3 }
        if trusted.count >= 2 {
            let spread = trusted.map(\.lagMs).max()! - trusted.map(\.lagMs).min()!
            let inSync = spread <= 40
            row(inSync, "sync", String(format: "%@ %.0f ms across %d windows",
                                       inSync ? "lag steady within" : "drifting: lag varies by", spread, trusted.count))
            ok = ok && inSync
        } else {
            row(nil, "sync", "not measurable " + Style.dim("(mic didn't hear system audio, e.g. headphones); check by ear"))
        }
        for l in lags {
            let weak = l.correlation < 0.3
            let text = String(format: "%@  mic lags by %+4.0f ms  r=%.2f", clock(l.at), l.lagMs, l.correlation)
            print("          " + (weak ? Style.faint(text + "  weak, ignored") : Style.dim(text)))
        }
        print("")
        print(ok ? Style.paint(" PASS ", "1", "7", Style.green.fg) : Style.paint(" FAIL ", "1", "7", Style.red.fg))
        exit(ok ? 0 : 1)
    }

    private static func latestSession() -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: Paths.recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.json").path) }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func stats(_ x: [Float], rate: Double) -> (rmsDB: Double, peakDB: Double, silentFraction: Double) {
        func db(_ v: Double) -> Double { v > 0 ? 20 * log10(v) : -120 }
        var sum = 0.0, peak: Float = 0
        var silentSeconds = 0, seconds = 0
        let window = Int(rate)
        var i = 0
        while i < x.count {
            let end = min(i + window, x.count)
            var ws = 0.0
            for j in i..<end { ws += Double(x[j] * x[j]); peak = max(peak, abs(x[j])) }
            sum += ws
            if (ws / Double(end - i)).squareRoot() < Recorder.silenceThreshold { silentSeconds += 1 }
            seconds += 1
            i = end
        }
        return (db((sum / Double(max(x.count, 1))).squareRoot()), db(Double(peak)),
                seconds > 0 ? Double(silentSeconds) / Double(seconds) : 1)
    }

    private struct Lag { let at: Double; let lagMs: Double; let correlation: Double }

    private static func syncLags(system: [Float], mic: [Float], rate: Double) -> [Lag] {
        let hop = Int(rate / 100)  // 10 ms
        func envelope(_ x: [Float]) -> [Double] {
            stride(from: 0, to: x.count - hop, by: hop).map { i in
                var s = 0.0
                for j in i..<i + hop { s += Double(x[j] * x[j]) }
                return (s / Double(hop)).squareRoot()
            }
        }
        let a = envelope(system), b = envelope(mic)
        let n = min(a.count, b.count)
        let window = 3000, maxLag = 50  // 30 s windows, ±500 ms
        guard n > window + 2 * maxLag else { return [] }
        var starts = Array(stride(from: maxLag, to: n - window - maxLag, by: 6000))
        if let last = starts.last, n - window - maxLag - last > 1000 { starts.append(n - window - maxLag) }

        return starts.map { start in
            var best = (lag: 0, r: -1.0)
            for lag in -maxLag...maxLag {
                let r = pearson(a, start, b, start + lag, window)
                if r > best.r { best = (lag, r) }
            }
            return Lag(at: Double(start) / 100, lagMs: Double(best.lag * 10), correlation: best.r)
        }
    }

    private static func pearson(_ a: [Double], _ ai: Int, _ b: [Double], _ bi: Int, _ n: Int) -> Double {
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for k in 0..<n {
            let x = a[ai + k], y = b[bi + k]
            sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
        }
        let N = Double(n)
        let cov = sab - sa * sb / N
        let va = saa - sa * sa / N, vb = sbb - sb * sb / N
        guard va > 1e-12, vb > 1e-12 else { return 0 }
        return cov / (va * vb).squareRoot()
    }
}
