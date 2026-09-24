import Foundation
import os

/// Decoded audio owned for the lifetime of the app (never freed while the render thread could read it).
final class PCMBuffer: @unchecked Sendable {
    let l: UnsafeMutablePointer<Float>
    let r: UnsafeMutablePointer<Float>
    let count: Int
    init(l: [Float], r: [Float]) {
        count = min(l.count, r.count)
        self.l = .allocate(capacity: count + 4)
        self.r = .allocate(capacity: count + 4)
        l.withUnsafeBufferPointer { self.l.update(from: $0.baseAddress!, count: count) }
        r.withUnsafeBufferPointer { self.r.update(from: $0.baseAddress!, count: count) }
        for k in 0..<4 { self.l[count + k] = 0; self.r[count + k] = 0 }
    }
}

// MARK: - small DSP building blocks

struct Ramp {
    var v: Float
    var target: Float
    var step: Float = 0
    var left = 0
    init(_ v: Float) { self.v = v; self.target = v }
    mutating func set(_ t: Float, over n: Int) {
        if n <= 0 { v = t; target = t; left = 0 } else { target = t; step = (t - v) / Float(n); left = n }
    }
    @inline(__always) mutating func tick() -> Float {
        if left > 0 { v += step; left -= 1; if left == 0 { v = target } }
        return v
    }
}

struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1L: Float = 0, z2L: Float = 0, z1R: Float = 0, z2R: Float = 0

    static func coeffs(lowpass: Bool, f: Double, q: Double, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w = 2 * Double.pi * min(f, sr * 0.45) / sr
        let cw = cos(w), alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        if lowpass {
            let b1 = (1 - cw) / a0
            return (Float(b1 / 2), Float(b1), Float(b1 / 2), Float(-2 * cw / a0), Float((1 - alpha) / a0))
        } else {
            let b1 = -(1 + cw) / a0
            return (Float(-b1 / 2), Float(b1), Float(-b1 / 2), Float(-2 * cw / a0), Float((1 - alpha) / a0))
        }
    }
    mutating func set(lowpass: Bool, f: Double, q: Double, sr: Double) {
        (b0, b1, b2, a1, a2) = Biquad.coeffs(lowpass: lowpass, f: f, q: q, sr: sr)
    }
    @inline(__always) mutating func run(_ l: Float, _ r: Float) -> (Float, Float) {
        let yl = b0 * l + z1L
        z1L = b1 * l - a1 * yl + z2L
        z2L = b2 * l - a2 * yl
        let yr = b0 * r + z1R
        z1R = b1 * r - a1 * yr + z2R
        z2R = b2 * r - a2 * yr
        return (yl, yr)
    }
}

// MARK: - performance vocabulary

enum ScratchStyle: Int, CaseIterable, Codable, Sendable {
    case baby, chirp, transformer, scribble, tear, flare
    var name: String { ["baby", "chirp", "transformer", "scribble", "tear", "flare"][rawValue] }
    /// strokes: (t0, t1, p0, p1, fader) in beats / fraction of the stab. fader: 1 open, 0 closed, 2 gate, 3 scribble, 4 flare
    static let table: [[(Double, Double, Double, Double, Int)]] = [
        [(0, 0.5, 0, 1, 1), (0.5, 1, 1, 0, 1)],                                                        // baby
        [(0, 0.25, 0, 1, 1), (0.25, 0.5, 1, 0, 0), (0.5, 0.75, 0, 1, 1), (0.75, 1, 1, 0, 0)],           // chirp
        [(0, 1, 0, 1, 2), (1, 2, 1, 0, 2)],                                                            // transformer
        [(0, 1, 0, 1, 3), (1, 1.25, 1, 0, 1), (1.25, 2, 0, 0, 0)],                                     // scribble
        [(0, 0.125, 0, 0.5, 1), (0.125, 0.25, 0.5, 0.5, 1), (0.25, 0.375, 0.5, 1, 1), (0.375, 0.5, 1, 0.5, 1), (0.5, 1, 0.5, 0, 1)], // tear
        [(0, 0.5, 0, 1, 4), (0.5, 1, 1, 0, 4)],                                                        // flare
    ]
    var cells: [(Double, Double, Double, Double, Int)] { ScratchStyle.table[rawValue] }
}

enum ReadMode {
    case play
    case scratch(style: ScratchStyle, stab: Double, len: Double, start: Int64)
    case roll(size: Double, anchor: Double, start: Int64)
    case brake(start: Int64, len: Double, from: Double)
    case spinback(start: Int64, len: Double, from: Double)
    case mute
}

enum DeckAction {
    case start(pos: Double)          // start playing from a source sample position (gain ramps in fast)
    case stop                        // quick fade then stop
    case gain(Float, ramp: Int)      // linear
    case low(Float, ramp: Int)       // linear band gains (0 = kill)
    case mid(Float, ramp: Int)
    case high(Float, ramp: Int)
    case filter(Float, ramp: Int)    // -1 low-pass … 0 … +1 high-pass
    case echo(Float, ramp: Int)      // send 0…1
    case mode(ReadMode)
    case resetEQ
}

enum MasterAction { case impact(Float), riser(len: Int, gain: Float) }

struct DJEvent {
    var at: Int64
    var deck: Int      // -1 = master
    var action: DeckAction?
    var master: MasterAction?
}

// MARK: - a deck

struct DeckState {
    var buf: PCMBuffer?
    var trackBPM: Double = 120
    var rate: Double = 1          // source samples per output sample (varispeed to the master tempo)
    var pos: Double = 0           // "ghost" playhead in source samples (keeps time through slip-mode FX)
    var readPos: Double = 0       // where the needle actually is (for the platter drawing)
    var playing = false
    var mode: ReadMode = .play
    var gain = Ramp(1), low = Ramp(1), mid = Ramp(1), high = Ramp(1), filter = Ramp(0), echo = Ramp(0)
    var fader = Ramp(1)           // manual channel fader
    var env: Float = 1
    var prevRead: Double = 0
    var lowF = Biquad(), highF = Biquad(), knobLP = Biquad(), knobHP = Biquad(), dc = Biquad()
    var lastKnob: Float = 99
    var rms: Float = 0
}

/// The whole booth in one render callback: two decks, isolator EQs, DJ filters, scratch synth,
/// slip-mode rolls, brake/spinback, crossfader, tempo-synced echo bus, impact + riser one-shots, soft limiter.
final class DJCore: @unchecked Sendable {
    let sr: Double
    var decks = [DeckState(), DeckState()]
    var masterBPM: Double = 120
    var crossfader: Float = 0     // -1 A … +1 B (manual)
    var masterGain: Float = 0.9
    private(set) var now: Int64 = 0
    var running = false

    // echo bus (ping-pong, dotted 8th)
    private let echoCap = 262_144
    private var echoL: UnsafeMutablePointer<Float>
    private var echoR: UnsafeMutablePointer<Float>
    private var echoW = 0
    private var echoLP = Biquad(), echoHP = Biquad()
    // one-shots
    private var impactT = -1, impactGain: Float = 0
    private var riserT = -1, riserLen = 1, riserGain: Float = 0, riserHP = Biquad(), riserLastF: Double = 0
    private var rng: UInt32 = 0x9E3779B9

    private var lock = os_unfair_lock()
    private var pending: [DJEvent] = []
    private var queue: [DJEvent] = []
    var masterRMS: Float = 0

    init(sampleRate: Double) {
        sr = sampleRate
        echoL = .allocate(capacity: 262_144); echoL.initialize(repeating: 0, count: 262_144)
        echoR = .allocate(capacity: 262_144); echoR.initialize(repeating: 0, count: 262_144)
        pending.reserveCapacity(1024); queue.reserveCapacity(1024)
        echoLP.set(lowpass: true, f: 5200, q: 0.7, sr: sr)
        echoHP.set(lowpass: false, f: 320, q: 0.7, sr: sr)
        for i in 0..<2 {
            decks[i].lowF.set(lowpass: true, f: 220, q: 0.707, sr: sr)
            decks[i].highF.set(lowpass: false, f: 2800, q: 0.707, sr: sr)
            decks[i].dc.set(lowpass: false, f: 28, q: 0.707, sr: sr)
        }
    }

    var samplesPerBeat: Double { sr * 60 / masterBPM }
    var samplesPerBar: Double { samplesPerBeat * 4 }

    func schedule(_ events: [DJEvent]) {
        os_unfair_lock_lock(&lock); pending.append(contentsOf: events); os_unfair_lock_unlock(&lock)
    }

    func setBuffer(_ deck: Int, _ buf: PCMBuffer, bpm: Double) {
        os_unfair_lock_lock(&lock)
        decks[deck].buf = buf
        decks[deck].trackBPM = bpm
        decks[deck].rate = masterBPM / bpm
        decks[deck].playing = false
        decks[deck].mode = .play
        os_unfair_lock_unlock(&lock)
    }

    func setMasterBPM(_ bpm: Double) {
        os_unfair_lock_lock(&lock)
        masterBPM = bpm
        for i in 0..<2 { decks[i].rate = bpm / decks[i].trackBPM }
        os_unfair_lock_unlock(&lock)
    }

    func resetClock() { os_unfair_lock_lock(&lock); now = 0; queue.removeAll(keepingCapacity: true); pending.removeAll(keepingCapacity: true); os_unfair_lock_unlock(&lock) }

    // MARK: render

    @inline(__always) private func noise() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng) / Float(UInt32.max) * 2 - 1
    }

    @inline(__always) private func read(_ b: PCMBuffer, _ p: Double) -> (Float, Float) {
        if p < 0 || p >= Double(b.count - 1) { return (0, 0) }
        let i = Int(p), f = Float(p - Double(i))
        return (b.l[i] + (b.l[i + 1] - b.l[i]) * f, b.r[i] + (b.r[i + 1] - b.r[i]) * f)
    }

    private func apply(_ e: DJEvent) {
        if let m = e.master {
            switch m {
            case .impact(let g): impactT = 0; impactGain = g
            case .riser(let len, let g): riserT = 0; riserLen = max(1, len); riserGain = g
            }
            return
        }
        guard let a = e.action, e.deck >= 0, e.deck < 2 else { return }
        let fast = Int(0.004 * sr)
        switch a {
        case .start(let p):
            decks[e.deck].pos = p; decks[e.deck].readPos = p; decks[e.deck].prevRead = p
            decks[e.deck].playing = true; decks[e.deck].mode = .play
            decks[e.deck].gain.v = 0; decks[e.deck].gain.set(1, over: fast)
        case .stop:
            decks[e.deck].gain.set(0, over: fast)
            decks[e.deck].echo.set(0, over: fast)
        case .gain(let g, let n): decks[e.deck].gain.set(g, over: n)
        case .low(let g, let n): decks[e.deck].low.set(g, over: n)
        case .mid(let g, let n): decks[e.deck].mid.set(g, over: n)
        case .high(let g, let n): decks[e.deck].high.set(g, over: n)
        case .filter(let g, let n): decks[e.deck].filter.set(g, over: n)
        case .echo(let g, let n): decks[e.deck].echo.set(g, over: n)
        case .mode(var m):
            // negative anchors mean "wherever the needle is right now"
            switch m {
            case .roll(let size, let anchor, let start) where anchor < 0: m = .roll(size: size, anchor: decks[e.deck].pos, start: start)
            case .brake(let start, let len, let from) where from < 0: m = .brake(start: start, len: len, from: decks[e.deck].pos); decks[e.deck].readPos = decks[e.deck].pos
            case .spinback(let start, let len, let from) where from < 0: m = .spinback(start: start, len: len, from: decks[e.deck].pos); decks[e.deck].readPos = decks[e.deck].pos
            default: break
            }
            decks[e.deck].mode = m
            decks[e.deck].prevRead = decks[e.deck].readPos
        case .resetEQ:
            for band in [\DeckState.low, \DeckState.mid, \DeckState.high] { decks[e.deck][keyPath: band].set(1, over: fast) }
            decks[e.deck].filter.set(0, over: fast)
            decks[e.deck].echo.set(0, over: fast)
        }
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if os_unfair_lock_trylock(&lock) {
            if !pending.isEmpty {
                queue.append(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
                queue.sort { $0.at < $1.at }
            }
            os_unfair_lock_unlock(&lock)
        }
        guard running else {
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            return
        }
        let spb = samplesPerBeat
        let echoDelay = Int(0.75 * spb) % echoCap
        var acc: (Float, Float, Float) = (0, 0, 0)
        var qi = 0
        for i in 0..<frames {
            while qi < queue.count && queue[qi].at <= now { apply(queue[qi]); qi += 1 }
            var outL: Float = 0, outR: Float = 0
            var sendL: Float = 0, sendR: Float = 0
            for d in 0..<2 {
                guard decks[d].playing, let b = decks[d].buf else { continue }
                var dk = decks[d]
                var rp = dk.pos
                var env: Float = 1
                switch dk.mode {
                case .play:
                    rp = dk.pos
                case .mute:
                    env = 0
                case .roll(let size, let anchor, let start):
                    let el = Double(now - start) * dk.rate
                    rp = anchor + el.truncatingRemainder(dividingBy: max(64, size))
                    let ph = el.truncatingRemainder(dividingBy: max(64, size))
                    env = Float(min(1, min(ph, max(64, size) - ph) / 64))
                case .scratch(let style, let stab, let len, let start):
                    let tb = Double(now - start) / spb
                    let cells = style.cells
                    let cellLen = cells.last!.1
                    let tc = tb.truncatingRemainder(dividingBy: cellLen)
                    var p = 0.0, fad: Float = 0
                    for c in cells where tc >= c.0 && tc < c.1 {
                        let u = (tc - c.0) / (c.1 - c.0)
                        let e = 0.5 - 0.5 * cos(Double.pi * u)
                        p = c.2 + (c.3 - c.2) * e
                        switch c.4 {
                        case 0: fad = 0
                        case 2: fad = tc.truncatingRemainder(dividingBy: 0.125) < 0.07 ? 1 : 0
                        case 3: p += 0.045 * sin(2 * Double.pi * 7 * u * (c.1 - c.0) * 4); fad = 1
                        case 4: fad = (u > 0.45 && u < 0.58) ? 0 : 1
                        default: fad = 1
                        }
                    }
                    rp = stab + p * len
                    let vel = abs(rp - dk.prevRead)
                    env = min(1, Float(vel / 0.25)) * fad
                case .brake(let start, let len, let from):
                    let u = min(1, Double(now - start) / max(1, len))
                    let sp = pow(1 - u, 1.4)
                    dk.readPos += sp * dk.rate
                    rp = from + (dk.readPos - from)
                    env = Float(1 - 0.7 * u) * (u >= 1 ? 0 : 1)
                case .spinback(let start, let len, let from):
                    let u = min(1, Double(now - start) / max(1, len))
                    dk.readPos -= (1 + 7 * u * u) * dk.rate
                    rp = min(from, dk.readPos)
                    env = Float(pow(1 - u, 0.7))
                }
                switch dk.mode { case .brake, .spinback: break; default: dk.readPos = rp }
                // smooth the envelope (fader clicks ~2 ms)
                dk.env += (env - dk.env) * 0.02
                dk.prevRead = rp
                var (l, r) = read(b, rp)
                l *= dk.env; r *= dk.env
                // isolator EQ: bands sum flat when all gains are 1
                let g0 = dk.low.tick(), g1 = dk.mid.tick(), g2 = dk.high.tick()
                let (lo_l, lo_r) = dk.lowF.run(l, r)
                let (hi_l, hi_r) = dk.highF.run(l, r)
                l = lo_l * g0 + (l - lo_l - hi_l) * g1 + hi_l * g2
                r = lo_r * g0 + (r - lo_r - hi_r) * g1 + hi_r * g2
                // DJ filter knob (resonant), coefficients refreshed when the knob moves
                let k = dk.filter.tick()
                if abs(k - dk.lastKnob) > 0.002 && (i & 15) == 0 {
                    dk.lastKnob = k
                    if k < -0.01 { dk.knobLP.set(lowpass: true, f: 20000 * pow(40.0 / 20000.0, Double(-k)), q: 1.1, sr: sr) }
                    if k > 0.01 { dk.knobHP.set(lowpass: false, f: 20 * pow(8000.0 / 20.0, Double(k)), q: 1.1, sr: sr) }
                }
                if dk.lastKnob < -0.01 { (l, r) = dk.knobLP.run(l, r) } else if dk.lastKnob > 0.01 { (l, r) = dk.knobHP.run(l, r) }
                (l, r) = dk.dc.run(l, r)
                let xf: Float = d == 0 ? min(1, 1 - crossfader) : min(1, 1 + crossfader)
                let g = dk.gain.tick() * dk.fader.tick() * xf
                l *= g; r *= g
                let es = dk.echo.tick()
                sendL += l * es; sendR += r * es
                outL += l; outR += r
                dk.rms += (l * l - dk.rms) * 0.0005
                if dk.gain.v <= 0.0001 && dk.gain.left == 0 && dk.gain.target == 0 { dk.playing = false }
                dk.pos += dk.rate
                decks[d] = dk
            }
            // echo bus
            let ri = (echoW - echoDelay + echoCap) % echoCap
            let dl = echoL[ri], dr = echoR[ri]
            let (fl, fr) = echoHP.run(sendL, sendR)
            let (bl, br) = echoLP.run(fl + dr * 0.55, fr + dl * 0.55)   // ping-pong feedback
            echoL[echoW] = bl; echoR[echoW] = br
            echoW = (echoW + 1) % echoCap
            outL += dl * 0.8; outR += dr * 0.8
            // one-shots
            if impactT >= 0 {
                let t = Double(impactT) / sr
                if t > 2.5 { impactT = -1 } else {
                    let f = 30 + 35 * exp(-t * 5)
                    let s = Float(sin(2 * Double.pi * (30 * t + 7 * (1 - exp(-t * 5))))) * Float(exp(-t * 2.2)) * 0.32
                    let n = noise() * Float(exp(-t * 16)) * 0.08
                    _ = f
                    outL += (s + n) * impactGain; outR += (s + n) * impactGain
                    impactT += 1
                }
            }
            if riserT >= 0 {
                let u = Double(riserT) / Double(riserLen)
                if u >= 1 { riserT = -1 } else {
                    if (riserT & 63) == 0 { riserHP.set(lowpass: false, f: 200 * pow(40, u), q: 1.4, sr: sr) }
                    let (nl, nr) = riserHP.run(noise(), noise())
                    let g = Float(u * u) * riserGain * 0.25
                    outL += nl * g; outR += nr * g
                    riserT += 1
                }
            }
            // soft limiter
            outL *= masterGain; outR *= masterGain
            left[i] = outL / (1 + abs(outL) * 0.35)
            right[i] = outR / (1 + abs(outR) * 0.35)
            acc.0 += left[i] * left[i]
            now += 1
        }
        if qi > 0 { queue.removeFirst(qi) }
        masterRMS = masterRMS * 0.8 + sqrt(acc.0 / Float(max(1, frames))) * 0.2
    }
}
