import AVFoundation
import Accelerate

struct TrackAnalysis: Sendable {
    var bpm: Double
    var firstDownbeat: Double        // seconds
    var bars: Int
    var barEnergy: [Float]           // 0…1 per bar
    var hookBar: Int
    var altBar: Int
    var stabBeat: Double             // beats from the first downbeat
    var wave: [SIMD3<Float>]         // per 512-sample bin: low / mid / high energy 0…1
    static let hop = 512

    var beatSec: Double { 60 / bpm }
    var barSec: Double { 240 / bpm }
    func barSample(_ bar: Int, sr: Double) -> Double { (firstDownbeat + Double(bar) * barSec) * sr }
}

enum Decoder {
    /// Decode any AVFoundation-readable file to 44.1 kHz stereo float.
    static func decode(_ url: URL, sr: Double = 44100) throws -> (l: [Float], r: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: inBuf)
        let conv = AVAudioConverter(from: inFmt, to: outFmt)!
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * sr / inFmt.sampleRate + 4096)
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)!
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let err { throw err }
        let n = Int(outBuf.frameLength)
        let l = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
        let r = inFmt.channelCount > 1 || outFmt.channelCount > 1 ? Array(UnsafeBufferPointer(start: outBuf.floatChannelData![1], count: n)) : l
        return (l, r)
    }
}

enum Analyzer {
    static func analyze(l: [Float], r: [Float], sr: Double = 44100, bpmHint: Double? = nil) -> TrackAnalysis {
        let n = l.count
        var mono = [Float](repeating: 0, count: n)
        vDSP.add(l, r, result: &mono)
        vDSP.multiply(0.5, mono, result: &mono)
        // band-split once for onsets + the colour waveform
        func filtered(_ lowpass: Bool, _ f: Double) -> [Float] {
            var bq = Biquad(); bq.set(lowpass: lowpass, f: f, q: 0.707, sr: sr)
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n { out[i] = bq.run(mono[i], 0).0 }
            return out
        }
        let low = filtered(true, 150), high = filtered(false, 2500)
        let hop = TrackAnalysis.hop, frames = n / hop
        var eAll = [Float](repeating: 0, count: frames), eLow = eAll, eHigh = eAll
        mono.withUnsafeBufferPointer { m in
            low.withUnsafeBufferPointer { lo in
                high.withUnsafeBufferPointer { hi in
                    for f in 0..<frames {
                        let s = f * hop
                        eAll[f] = vDSP.sumOfSquares(UnsafeBufferPointer(rebasing: m[s..<s + hop])) / Float(hop)
                        eLow[f] = vDSP.sumOfSquares(UnsafeBufferPointer(rebasing: lo[s..<s + hop])) / Float(hop)
                        eHigh[f] = vDSP.sumOfSquares(UnsafeBufferPointer(rebasing: hi[s..<s + hop])) / Float(hop)
                    }
                }
            }
        }
        func onset(_ e: [Float]) -> [Float] {
            var o = [Float](repeating: 0, count: e.count)
            var prev = log10((e.first ?? 0) + 1e-9)
            for i in 0..<e.count { let v = log10(e[i] + 1e-9); o[i] = max(0, v - prev); prev = v }
            return o
        }
        let oAll = onset(eAll), oLow = onset(eLow), oHigh = onset(eHigh)
        var on = [Float](repeating: 0, count: frames)
        for i in 0..<frames { on[i] = oAll[i] + 1.2 * oLow[i] + 0.6 * oHigh[i] }
        let fps = sr / Double(hop)

        // --- tempo: autocorrelation with a soft prior, then a fine comb search
        func interp(_ a: [Float], _ x: Double) -> Float {
            let i = Int(x); if i < 0 || i >= a.count - 1 { return 0 }
            let f = Float(x - Double(i)); return a[i] * (1 - f) + a[i + 1] * f
        }
        var best = (score: -Float.infinity, bpm: 120.0)
        for bpmTry in stride(from: 70.0, through: 180.0, by: 0.5) {
            let lag = fps * 60 / bpmTry
            var s: Float = 0
            var i = 0.0
            while i + lag * 4 < Double(frames) {
                s += interp(on, i) * (interp(on, i + lag) + 0.5 * interp(on, i + 2 * lag) + 0.5 * interp(on, i + 4 * lag))
                i += 1
            }
            var prior = Float(exp(-pow(log2(bpmTry / 118), 2) / (2 * 0.5 * 0.5)))
            if let h = bpmHint, h > 40 {
                let d = min(abs(log2(bpmTry / h)), abs(log2(bpmTry / h / 2)), abs(log2(bpmTry / h * 2)))
                prior *= d < 0.02 ? 3 : 1
            }
            let sc = s * (0.6 + prior)
            if sc > best.score { best = (sc, bpmTry) }
        }
        var bpm = best.bpm
        var phaseBest = (score: -Float.infinity, bpm: bpm, phase: 0.0)
        for b in stride(from: bpm * 0.985, through: bpm * 1.015, by: 0.01) {
            let period = fps * 60 / b
            for ph in stride(from: 0.0, to: period, by: 0.5) {
                var s: Float = 0, k = ph
                while k < Double(frames) { s += interp(on, k); k += period }
                if s > phaseBest.score { phaseBest = (s, b, ph) }
            }
        }
        bpm = phaseBest.bpm
        let period = fps * 60 / bpm
        // --- downbeat: the beat phase (mod 4) where kicks and energy jumps land
        // Three cues, each normalised across the 4 candidate phases:
        //  • kicks/bass onsets on beat 1   • harmonic/timbral change at the bar line   • section changes align with bars
        let nBeats = Int((Double(frames) - phaseBest.phase) / period)
        var beatVec = [SIMD3<Float>](repeating: .zero, count: max(0, nBeats))
        for i in 0..<beatVec.count {
            let s = Int(phaseBest.phase + Double(i) * period), e = min(frames, Int(phaseBest.phase + Double(i + 1) * period))
            guard e > s else { continue }
            var v = SIMD3<Float>(repeating: 0)
            for f in s..<e { v += SIMD3(eLow[f], max(0, eAll[f] - eLow[f] - eHigh[f]), eHigh[f]) }
            v /= Float(e - s)
            beatVec[i] = SIMD3(log10(v.x + 1e-9), log10(v.y + 1e-9), log10(v.z + 1e-9))
        }
        func l1(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { let d = a - b; return abs(d.x) + abs(d.y) + abs(d.z) }
        var cues = [[Float]](repeating: [0, 0, 0, 0], count: 3)
        for k in 0..<4 {
            var x = phaseBest.phase + Double(k) * period
            while x < Double(frames) { cues[0][k] += interp(oLow, x) * 1.5 + interp(oAll, x); x += period * 4 }
            var i = k
            while i < beatVec.count { if i > 0 { cues[1][k] += l1(beatVec[i], beatVec[i - 1]) }; i += 4 }
            i = k + 4
            while i + 4 <= beatVec.count {   // bar-window vectors: compare consecutive bars aligned to phase k
                var a = SIMD3<Float>(repeating: 0), b = a
                for j in 0..<4 { a += beatVec[i - 4 + j]; b += beatVec[i + j] }
                cues[2][k] += l1(a, b)
                i += 4
            }
        }
        var dbBest = (score: -Float.infinity, k: 0)
        for k in 0..<4 {
            var s: Float = 0
            // weights fitted on 16 hand-checked tracks
            for (c, w) in zip(cues, [Float(2.0), 1.0, -0.5]) {
                let mean = c.reduce(0, +) / 4, sd = sqrt(c.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 4) + 1e-9
                s += w * (c[k] - mean) / sd
            }
            if s > dbBest.score { dbBest = (s, k) }
        }
        var firstDB = (phaseBest.phase + Double(dbBest.k) * period) / fps
        while firstDB - 4 * 60 / bpm >= 0 { firstDB -= 4 * 60 / bpm }
        let barSec = 240 / bpm
        let bars = max(1, Int((Double(n) / sr - firstDB) / barSec))
        // --- per-bar energy, hook, stab
        var barE = [Float](repeating: 0, count: bars)
        for b in 0..<bars {
            let s = Int((firstDB + Double(b) * barSec) * fps), e = min(frames, Int((firstDB + Double(b + 1) * barSec) * fps))
            if e > s { barE[b] = sqrt(eAll[s..<e].reduce(0, +) / Float(e - s)) }
        }
        let mx = barE.max() ?? 1
        barE = barE.map { $0 / max(mx, 1e-6) }
        var hook = min(8, max(0, bars - 8)), hookScore = -Float.infinity
        var scores: [(Int, Float)] = []
        for c in stride(from: 4, to: max(5, bars - 8), by: 4) {
            let blk = barE[c..<min(bars, c + 8)]
            var sc = blk.reduce(0, +) / Float(blk.count)
            sc += 0.6 * max(0, barE[c] - barE[max(0, c - 1)])          // drops start with a jump
            if c < 8 { sc -= 0.25 }
            scores.append((c, sc))
            if sc > hookScore { hookScore = sc; hook = c }
        }
        let alt = scores.sorted { $0.1 > $1.1 }.first { abs($0.0 - hook) >= 16 }?.0 ?? hook
        var stab = Double(hook * 4), stabScore: Float = -1
        for k in 0..<16 {
            let beat = Double(hook * 4) + Double(k) * 0.5
            let x = (firstDB + beat * 60 / bpm) * fps
            var s: Float = 0
            for d in -2...6 { s = max(s, interp(oAll, x + Double(d)) + interp(oHigh, x + Double(d))) }
            if s > stabScore { stabScore = s; stab = beat }
        }
        // --- colour waveform
        func norm(_ a: [Float]) -> [Float] { let m = a.max() ?? 1; return a.map { sqrt($0 / max(m, 1e-9)) } }
        let nl = norm(eLow), nh = norm(eHigh), na = norm(eAll)
        var wave = [SIMD3<Float>](repeating: .zero, count: frames)
        for i in 0..<frames { wave[i] = SIMD3(nl[i], max(0, na[i] - 0.5 * nl[i]), nh[i]) }
        return TrackAnalysis(bpm: bpm, firstDownbeat: firstDB, bars: bars, barEnergy: barE, hookBar: hook, altBar: alt,
                             stabBeat: stab, wave: wave)
    }
}
