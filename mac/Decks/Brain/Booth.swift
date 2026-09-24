import Foundation
import Observation
import SwiftUI

enum Move: String, CaseIterable, Identifiable, Sendable {
    case ride, scratchFill = "scratch_fill", rollFill = "roll_fill", echoThrow = "echo_throw", filterDip = "filter_dip"
    case scratchIn = "scratch_in", chopCut = "chop_cut", echoOut = "echo_out_cut", spinback = "spinback_cut"
    case brake = "brake_cut", rollBuild = "roll_build_cut", dropGap = "drop_gap_cut"
    var id: String { rawValue }
    var isTransition: Bool { rawValue.hasSuffix("_cut") || self == .scratchIn }
    var title: String {
        switch self {
        case .ride: "Ride"; case .scratchFill: "Scratch fill"; case .rollFill: "Roll fill"; case .echoThrow: "Echo throw"
        case .filterDip: "Filter dip"; case .scratchIn: "Scratch in"; case .chopCut: "Chops"; case .echoOut: "Echo out"
        case .spinback: "Spinback"; case .brake: "Brake"; case .rollBuild: "Roll build"; case .dropGap: "Drop gap"
        }
    }
    var symbol: String {
        switch self {
        case .ride: "play"; case .scratchFill: "hand.draw"; case .rollFill: "repeat"; case .echoThrow: "wave.3.right"
        case .filterDip: "water.waves"; case .scratchIn: "hand.point.up.left.and.text"; case .chopCut: "scissors"
        case .echoOut: "dot.radiowaves.right"; case .spinback: "arrow.counterclockwise"; case .brake: "stop.circle"
        case .rollBuild: "arrow.up.right.circle"; case .dropGap: "speaker.slash"
        }
    }
    var rubric: String {
        switch self {
        case .ride: "Let the song play untouched. Right when the groove is carrying the moment."
        case .scratchFill: "Scratch the current song's hook over the last two beats, then let it continue. A flashy fill on a phrase end."
        case .rollFill: "Stutter the last beat with a quick loop roll (1/4 then 1/8 beat) then continue. Tension on a phrase end."
        case .echoThrow: "Throw the last beat into a big echo while the song keeps playing. A classy accent."
        case .filterDip: "Sweep a low-pass filter down and back up across the bar for an underwater breakdown feel."
        case .scratchIn: "Kill the bass of the current song, scratch the NEXT song's hook over its beat for a bar, then slam the next song in on the 1. The signature transition."
        case .chopCut: "Crossfader chops: flip between current and next song every half beat for a bar, landing on the next song's hook."
        case .echoOut: "Throw the current song into echo on the last beat and cut it; the next song slams in on the 1."
        case .spinback: "Rewind the current song over the last two beats, then drop the next song."
        case .brake: "Vinyl-brake the current song to a stop over the last two beats, then drop the next song."
        case .rollBuild: "Loop-roll the current song shrinking 1 → 1/2 → 1/4 → 1/8 beat with a rising filter and noise, then drop the next song. Maximum build-up."
        case .dropGap: "One beat of silence, then the next song hits with a sub boom. Big impact."
        }
    }
    static let fills: [Move] = [.ride, .scratchFill, .rollFill, .echoThrow, .filterDip]
    static let transitions: [Move] = [.scratchIn, .chopCut, .echoOut, .spinback, .brake, .rollBuild, .dropGap]
}

struct Decision: Identifiable, Sendable {
    let id = UUID()
    var bar: Int
    var move: Move
    var wanted: String
    var probs: [(String, Double)]
    var ms: Double
    var late: Bool
    var scratch: String?
    var hype: Int
    var byHuman = false
}

struct LogLine: Identifiable, Sendable { let id = UUID(); let stamp: String; let text: String; let brain: Bool }

private struct Segment { var deck: Int; var startBar: Int; var cue: Int; var len: Int }

@MainActor @Observable
final class Booth {
    let audio = AudioEngine()
    var core: DJCore { audio.core }

    var tracks: [LoadedTrack?] = [nil, nil]
    var loadingText: [String?] = [nil, nil]
    var playing = false
    var autopilot = true
    var bar = 0
    var thinking = false
    var decisions: [Decision] = []
    var log: [LogLine] = []
    var apiKey: String? = Keychain.get("openrouter")
    var error: String?
    var crossfader: Float = 0 { didSet { core.crossfader = crossfader } }

    // conductor state
    private var seg: Segment?
    private var plays = [0, 0]
    private var history: [Move] = []
    private var scratchHistory: [String] = []
    private var decidedThrough = -1
    private var clock: Task<Void, Never>?
    private var endAt: Int?
    private let lookahead = 2

    var bpm: Double { core.masterBPM }
    var lastDecision: Decision? { decisions.last }

    // MARK: loading

    func load(_ info: TrackInfo, deck: Int) {
        loadingText[deck] = "cueing"
        Task {
            do {
                let t = try await Task.detached(priority: .userInitiated) {
                    try await Loader.load(info) { s in Task { @MainActor in self.loadingText[deck] = s } }
                }.value
                tracks[deck] = t
                loadingText[deck] = nil
                if !playing || seg?.deck != deck {
                    if tracks[1 - deck] == nil || !playing { core.setMasterBPM(t.analysis.bpm) }
                    core.setBuffer(deck, t.pcm, bpm: effectiveBPM(t))
                }
                say("deck_\(deck == 0 ? "a" : "b").load(\"\(t.info.title)\", bpm: \(String(format: "%.1f", t.analysis.bpm)))", brain: false)
            } catch {
                loadingText[deck] = nil
                self.error = "Couldn't load \(info.title): \(error.localizedDescription)"
            }
        }
    }

    /// Beat-grid fix: move "beat 1" by whole beats (auto downbeat detection is right ~2/3 of the time).
    func nudgeGrid(_ deck: Int, beats: Int) {
        guard let t = tracks[deck] else { return }
        var a = t.analysis
        a.firstDownbeat += Double(beats) * a.beatSec
        while a.firstDownbeat - a.barSec >= 0 { a.firstDownbeat -= a.barSec }
        while a.firstDownbeat < 0 { a.firstDownbeat += a.barSec }
        t.analysis = a
        tracks[deck] = t
        say("deck_\(abc(deck)).grid(beat_1: \(beats > 0 ? "+" : "")\(beats))", brain: false)
    }

    /// half/double-time aware tempo for a track against the current master
    private func effectiveBPM(_ t: LoadedTrack) -> Double {
        let b: Double = t.analysis.bpm, m: Double = core.masterBPM
        var best = b
        for c: Double in [b / 2, b * 2] where Swift.abs(Foundation.log(c / m)) < Swift.abs(Foundation.log(best / m)) { best = c }
        return best
    }
    private func factor(_ d: Int) -> Double { tracks[d].map { effectiveBPM($0) / $0.analysis.bpm } ?? 1 }

    // MARK: transport

    func togglePlay() { playing ? stop() : start() }

    func start() {
        guard let a = tracks[0] ?? tracks[1] else { return }
        let first = tracks[0] != nil ? 0 : 1
        core.setMasterBPM(a.analysis.bpm)
        for d in 0..<2 { if let t = tracks[d] { core.setBuffer(d, t.pcm, bpm: effectiveBPM(t)) } }
        core.resetClock()
        decisions = []; history = []; scratchHistory = []; plays = [0, 0]; endAt = nil
        let fastEQ = [DJEvent(at: 0, deck: 0, action: .resetEQ), DJEvent(at: 0, deck: 1, action: .resetEQ)]
        core.schedule(fastEQ)
        let hook = cueBar(first, 0)
        if autopilot && tracks[1 - first] != nil {
            // opener: scratch the first hook over silence, drop on bar 1
            core.schedule(scratchEvents(deck: first, at: 0, style: .baby, beats: 3.5, startPlayingFrom: hook - 1) +
                          [DJEvent(at: barSample(1), deck: first, action: .start(pos: sourceSample(first, hook))),
                           DJEvent(at: barSample(1), deck: -1, master: .impact(0.9))])
            seg = Segment(deck: first, startBar: 1, cue: hook, len: 8)
            say("deck_\(abc(first)).scratch(\"hook\", style: baby)", brain: true)
        } else {
            core.schedule([DJEvent(at: 0, deck: first, action: .start(pos: sourceSample(first, hook)))])
            seg = Segment(deck: first, startBar: 0, cue: hook, len: 8)
        }
        plays[first] = 1
        decidedThrough = 1
        core.running = true
        playing = true
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(12))
                self?.tick()
            }
        }
    }

    func stop() {
        clock?.cancel(); clock = nil
        core.schedule([DJEvent(at: core.now, deck: 0, action: .stop), DJEvent(at: core.now, deck: 1, action: .stop)])
        Task { try? await Task.sleep(for: .milliseconds(120)); core.running = false }
        playing = false; thinking = false; seg = nil
    }

    func endSet() { endAt = bar + lookahead + 1 }

    private func tick() {
        let b = Int(Double(core.now) / core.samplesPerBar)
        if b != bar { bar = b }
        if let e = endAt, b > e + 2 { stop(); return }
        let target = b + lookahead
        if target > decidedThrough, !thinking {
            decidedThrough = target
            decide(bar: target)
        }
    }

    // MARK: positions

    private func abc(_ d: Int) -> String { d == 0 ? "a" : "b" }
    private func barSample(_ bar: Int) -> Int64 { Int64((Double(bar) * core.samplesPerBar).rounded()) }
    private func beat(_ bar: Int, _ beats: Double) -> Int64 { Int64((Double(bar) * core.samplesPerBar + beats * core.samplesPerBeat).rounded()) }
    private func cueBar(_ d: Int, _ k: Int) -> Int {
        guard let t = tracks[d] else { return 0 }
        let f = factor(d)
        let cues = [t.analysis.hookBar, t.analysis.altBar].map { Int((Double($0) * f).rounded()) }
        return cues[k % cues.count]
    }
    /// source sample for bar `b` counted in the deck's effective (half/double-aware) bars
    private func sourceSample(_ d: Int, _ b: Int) -> Double {
        guard let t = tracks[d] else { return 0 }
        let effBarSec = 240 / effectiveBPM(t)
        return (t.analysis.firstDownbeat + Double(b) * effBarSec) * core.sr
    }
    private func stab(_ d: Int) -> (Double, Double) {
        guard let t = tracks[d] else { return (0, 1000) }
        let beatSec = 60 / t.analysis.bpm
        return ((t.analysis.firstDownbeat + t.analysis.stabBeat * beatSec) * core.sr, 0.75 * 60 / effectiveBPM(t) * core.sr)
    }

    // MARK: deciding

    private func decide(bar target: Int) {
        guard let s = seg else { return }
        let into = target - s.startBar
        let phraseEnd = into % 4 == 3
        let mustChange = into >= s.len - 1
        let final = endAt.map { target >= $0 } ?? false
        let hasOther = tracks[1 - s.deck] != nil
        var options: [Move]
        if final { options = [.echoOut, .brake, .spinback] }
        else if !autopilot { return }
        else if mustChange && hasOther { options = Move.transitions }
        else if phraseEnd && into >= 3 { options = Move.fills + (hasOther ? Move.transitions : []) }
        else { options = into % 4 == 1 ? [.ride, .filterDip, .echoThrow] : [.ride] }
        // variety is enforced in code
        let recent = history.suffix(6).filter { $0 != .ride }
        let lastTransitions = history.filter(\.isTransition).suffix(2)
        let pruned = options.filter { $0 == .ride || (!recent.suffix(2).contains($0) && !lastTransitions.contains($0) && !($0 == .filterDip && recent.contains(.filterDip))) }
        if final || pruned.contains(where: \.isTransition) || !options.contains(where: \.isTransition) { options = pruned.isEmpty ? options : pruned }
        guard options.count > 1 || final else { apply(.ride, at: target, scratch: .baby, hype: 2); return }

        let state: [String: Any] = [
            "gig": "A live DJ set. Songs switch every 4–8 bars; it must feel fun, surprising and hype, with DJ skills on show. Avoid repeating the same move back-to-back.",
            "now_playing": ["song": tracks[s.deck]?.info.title ?? "", "energy_this_bar": energyWord(s.deck, s.cue + into)],
            "timing": final ? "this is the FINAL bar of the set — end it with style"
                : mustChange ? "the hook is running out: this bar must transition to the next song"
                : phraseEnd ? (into >= 7 ? "last bar of a phrase; the song has played a while, a transition fits" : "last bar of a phrase; the song only just started")
                : "middle of a phrase — keep the groove going or add a small accent",
            "next_song": tracks[1 - s.deck]?.info.title ?? "none",
            "recent_moves": history.suffix(4).map(\.rawValue),
        ]
        let styles = Dictionary(uniqueKeysWithValues: ScratchStyle.allCases.filter { !scratchHistory.suffix(2).contains($0.name) }.map {
            ($0.name, ["baby": "smooth forward-back", "chirp": "fader cut on each push, punchy", "transformer": "fast fader stutter, robotic",
                       "scribble": "tense buzzing vibrato", "tear": "push split in two, funky", "flare": "fader clicks mid-stroke, battle flavour"][$0.name]!)
        })
        let moves = Dictionary(uniqueKeysWithValues: options.map { ($0.rawValue, $0.rubric) })
        let deadline = barSample(target) - Int64(0.03 * core.sr)
        guard let key = apiKey, !key.isEmpty else {
            let m = options.filter { $0 != .ride }.randomElement() ?? .ride
            record(Decision(bar: target, move: m, wanted: m.rawValue, probs: [], ms: 0, late: false, scratch: nil, hype: 2), options)
            apply(m, at: target, scratch: ScratchStyle.allCases.randomElement()!, hype: 2)
            return
        }
        thinking = true
        Task {
            var ans: JevAnswer?
            do { ans = try await Jev.decide(state: state, moves: moves, styles: styles, key: key) }
            catch { self.error = "Jev: \(error.localizedDescription)" }
            thinking = false
            let late = core.now > deadline
            let wanted = ans?.move ?? "error"
            var m = Move(rawValue: wanted) ?? .ride
            if late || !options.contains(m) { m = options.contains(.ride) ? .ride : (final ? .echoOut : .echoOut) }
            let style = ans?.scratch.flatMap { n in ScratchStyle.allCases.first { $0.name == n } } ?? .baby
            record(Decision(bar: target, move: m, wanted: wanted, probs: ans?.probs ?? [], ms: ans?.ms ?? 0, late: late,
                            scratch: m == .scratchIn || m == .scratchFill ? style.name : nil, hype: ans?.hype ?? 2), options)
            if late && core.now > barSample(target) { return }   // missed it entirely
            apply(m, at: target, scratch: style, hype: ans?.hype ?? 2)
        }
    }

    private func energyWord(_ d: Int, _ srcBar: Int) -> String {
        guard let e = tracks[d]?.analysis.barEnergy, !e.isEmpty else { return "unknown" }
        let v = e[max(0, min(e.count - 1, Int(Double(srcBar) / factor(d))))]
        return v > 0.8 ? "peak" : v > 0.55 ? "high" : v > 0.3 ? "medium" : "low / breakdown"
    }

    private func record(_ d: Decision, _ options: [Move]) {
        decisions.append(d)
        if decisions.count > 60 { decisions.removeFirst(decisions.count - 60) }
        history.append(d.move)
        if let s = d.scratch { scratchHistory.append(s) }
        if d.ms > 0 || d.byHuman {
            say("jev.decide(bar: \(d.bar)) → \(d.move.rawValue)  \(Int(d.ms)) ms" + (d.late ? "  LATE" : ""), brain: true)
        }
    }

    private func say(_ text: String, brain: Bool) {
        let b = Double(core.now) / core.samplesPerBeat
        log.append(LogLine(stamp: String(format: "%02d.%d", Int(b) / 4, Int(b) % 4 + 1), text: text, brain: brain))
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }

    // MARK: manual moves (quantised to the next bar)

    func perform(_ m: Move) {
        guard playing, let _ = seg else { return }
        let target = max(bar + 1, decidedThrough + 1)
        decidedThrough = target
        let style = ScratchStyle.allCases.randomElement()!
        record(Decision(bar: target, move: m, wanted: m.rawValue, probs: [], ms: 0, late: false, scratch: m == .scratchIn || m == .scratchFill ? style.name : nil, hype: 2, byHuman: true), [m])
        apply(m, at: target, scratch: style, hype: 2)
    }

    // MARK: moves → sample-accurate events

    private func scratchEvents(deck d: Int, at bar: Int, style: ScratchStyle, beats: Double, startPlayingFrom: Int) -> [DJEvent] {
        let (st, len) = stab(d)
        return [DJEvent(at: barSample(bar), deck: d, action: .start(pos: sourceSample(d, startPlayingFrom))),
                DJEvent(at: barSample(bar), deck: d, action: .mode(.scratch(style: style, stab: st, len: len, start: barSample(bar)))),
                DJEvent(at: barSample(bar), deck: d, action: .gain(1.25, ramp: 0)),
                DJEvent(at: beat(bar, beats), deck: d, action: .mode(.mute))]
    }

    private func apply(_ m: Move, at b: Int, scratch: ScratchStyle, hype: Int) {
        guard var s = seg else { return }
        let D = s.deck, N = 1 - s.deck
        let spbSrc = { (d: Int) -> Double in 60 / (self.tracks[d].map { self.effectiveBPM($0) } ?? 120) * self.core.sr }
        let ms = { (x: Double) in Int(x * self.core.sr / 1000) }
        var ev: [DJEvent] = []
        let final = endAt.map { b >= $0 } ?? false
        func land() {   // next song slams in on the 1
            let k = plays[N]; plays[N] += 1
            let cue = cueBar(N, k)
            ev += [DJEvent(at: barSample(b + 1), deck: N, action: .resetEQ),
                   DJEvent(at: barSample(b + 1), deck: N, action: .start(pos: sourceSample(N, cue))),
                   DJEvent(at: barSample(b + 1), deck: D, action: .stop)]
            s = Segment(deck: N, startBar: b + 1, cue: cue, len: 8)
            say("mixer.crossfade(to: deck_\(abc(N)))", brain: true)
        }
        switch m {
        case .ride: return
        case .filterDip:
            ev = [DJEvent(at: barSample(b), deck: D, action: .filter(-0.75, ramp: Int(2 * core.samplesPerBeat))),
                  DJEvent(at: beat(b, 3.6), deck: D, action: .filter(0, ramp: Int(0.4 * core.samplesPerBeat)))]
            say("mixer.filter(deck_\(abc(D)), lowpass: sweep)", brain: true)
        case .echoThrow:
            ev = [DJEvent(at: beat(b, 3), deck: D, action: .echo(0.9, ramp: ms(10))), DJEvent(at: beat(b, 4), deck: D, action: .echo(0, ramp: ms(30)))]
            say("fx.echo(deck_\(abc(D)), send: 90%)", brain: true)
        case .rollFill:
            ev = [DJEvent(at: beat(b, 3), deck: D, action: .mode(.roll(size: 0.25 * spbSrc(D), anchor: -1, start: beat(b, 3)))),
                  DJEvent(at: beat(b, 3.5), deck: D, action: .mode(.roll(size: 0.125 * spbSrc(D), anchor: -1, start: beat(b, 3.5)))),
                  DJEvent(at: beat(b, 4), deck: D, action: .mode(.play))]
            say("deck_\(abc(D)).roll(1/4 → 1/8)", brain: true)
        case .scratchFill:
            let (st, len) = stab(D)
            ev = [DJEvent(at: beat(b, 2), deck: D, action: .mode(.scratch(style: scratch, stab: st, len: len, start: beat(b, 2)))),
                  DJEvent(at: beat(b, 4), deck: D, action: .mode(.play))]
            say("deck_\(abc(D)).scratch(\"hook\", style: \(scratch.name))", brain: true)
        default:
            if final {
                switch m {
                case .brake: ev = [DJEvent(at: beat(b, 2), deck: D, action: .mode(.brake(start: beat(b, 2), len: 2 * core.samplesPerBeat, from: -1)))]
                case .spinback: ev = [DJEvent(at: beat(b, 2), deck: D, action: .mode(.spinback(start: beat(b, 2), len: 2 * core.samplesPerBeat, from: -1)))]
                default: ev = [DJEvent(at: beat(b, 3), deck: D, action: .echo(1, ramp: ms(10))), DJEvent(at: beat(b, 3), deck: D, action: .mode(.roll(size: spbSrc(D), anchor: -1, start: beat(b, 3))))]
                }
                ev.append(DJEvent(at: barSample(b + 1), deck: D, action: .stop))
                say("deck_\(abc(D)).\(m == .brake ? "brake()" : m == .spinback ? "spinback()" : "echo_out()")  // end of set", brain: true)
                break
            }
            guard tracks[N] != nil else { return }
            switch m {
            case .scratchIn:
                let (st, len) = stab(N)
                ev = [DJEvent(at: barSample(b), deck: D, action: .low(0, ramp: ms(8))),
                      DJEvent(at: barSample(b), deck: D, action: .mid(0.35, ramp: ms(8))),
                      DJEvent(at: barSample(b), deck: D, action: .filter(0.3, ramp: 0)),
                      DJEvent(at: barSample(b), deck: D, action: .filter(0.55, ramp: Int(3.5 * core.samplesPerBeat))),
                      DJEvent(at: barSample(b), deck: N, action: .start(pos: st)),
                      DJEvent(at: barSample(b), deck: N, action: .mode(.scratch(style: scratch, stab: st, len: len, start: barSample(b)))),
                      DJEvent(at: barSample(b), deck: N, action: .gain(1.35, ramp: 0)),
                      DJEvent(at: beat(b, 3.5), deck: N, action: .mode(.mute)),
                      DJEvent(at: barSample(b + 1), deck: -1, master: .impact(hype >= 2 ? 0.9 : 0.5))]
                say("deck_\(abc(N)).scratch(\"\(tracks[N]!.info.title)\", style: \(scratch.name))", brain: true)
            case .chopCut:
                let cue = cueBar(N, plays[N])
                ev = [DJEvent(at: barSample(b), deck: N, action: .start(pos: sourceSample(N, cue - 1)))]
                for i in 0..<8 {
                    let t = beat(b, Double(i) * 0.5)
                    ev.append(DJEvent(at: t, deck: N, action: .gain(i % 2 == 1 ? 1 : 0, ramp: ms(3))))
                    ev.append(DJEvent(at: t, deck: D, action: .gain(i % 2 == 1 ? 0 : 1, ramp: ms(3))))
                }
                say("mixer.crossfader_chops(every: 1/2 beat)", brain: true)
            case .echoOut:
                ev = [DJEvent(at: beat(b, 3), deck: D, action: .echo(1, ramp: ms(10))),
                      DJEvent(at: beat(b, 3), deck: D, action: .mode(.roll(size: spbSrc(D), anchor: -1, start: beat(b, 3))))]
                say("fx.echo_out(deck_\(abc(D)))", brain: true)
            case .spinback:
                ev = [DJEvent(at: beat(b, 2), deck: D, action: .mode(.spinback(start: beat(b, 2), len: 2 * core.samplesPerBeat, from: -1))),
                      DJEvent(at: barSample(b + 1), deck: -1, master: .impact(0.7))]
                say("deck_\(abc(D)).spinback()", brain: true)
            case .brake:
                ev = [DJEvent(at: beat(b, 2), deck: D, action: .mode(.brake(start: beat(b, 2), len: 2 * core.samplesPerBeat, from: -1))),
                      DJEvent(at: barSample(b + 1), deck: -1, master: .impact(0.7))]
                say("deck_\(abc(D)).brake()", brain: true)
            case .rollBuild:
                ev = [DJEvent(at: barSample(b), deck: D, action: .mode(.roll(size: spbSrc(D), anchor: -1, start: barSample(b)))),
                      DJEvent(at: beat(b, 2), deck: D, action: .mode(.roll(size: 0.5 * spbSrc(D), anchor: -1, start: beat(b, 2)))),
                      DJEvent(at: beat(b, 3), deck: D, action: .mode(.roll(size: 0.25 * spbSrc(D), anchor: -1, start: beat(b, 3)))),
                      DJEvent(at: beat(b, 3.5), deck: D, action: .mode(.roll(size: 0.125 * spbSrc(D), anchor: -1, start: beat(b, 3.5)))),
                      DJEvent(at: barSample(b), deck: D, action: .filter(0.75, ramp: Int(core.samplesPerBar))),
                      DJEvent(at: barSample(b), deck: -1, master: .riser(len: Int(core.samplesPerBar), gain: 0.8)),
                      DJEvent(at: barSample(b + 1), deck: -1, master: .impact(1))]
                say("deck_\(abc(D)).roll(1 → 1/8) + fx.riser()", brain: true)
            case .dropGap:
                ev = [DJEvent(at: beat(b, 3), deck: D, action: .gain(0, ramp: ms(5))),
                      DJEvent(at: barSample(b + 1), deck: -1, master: .impact(1))]
                say("mixer.mute(deck_\(abc(D)))  // drop gap", brain: true)
            default: break
            }
            land()
        }
        seg = s
        core.schedule(ev)
    }
}
