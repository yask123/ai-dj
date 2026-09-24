import SwiftUI

extension TrackInfo {
    var color: Color { Color(hue: hue, saturation: 0.72, brightness: 0.98) }
    var deepColor: Color { Color(hue: hue, saturation: 0.85, brightness: 0.45) }
}

/// Living light behind the glass: a slow mesh gradient in the two records' colours, breathing with the master level.
struct AmbientBackground: View {
    let booth: Booth
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let level = Double(min(1, booth.core.masterRMS * 4))
            let a = booth.tracks[0]?.info.deepColor ?? Color(hue: 0.03, saturation: 0.8, brightness: 0.35)
            let b = booth.tracks[1]?.info.deepColor ?? Color(hue: 0.58, saturation: 0.8, brightness: 0.35)
            let dark = Color(red: 0.035, green: 0.035, blue: 0.05)
            let w = { (p: Double) -> Float in Float(0.5 + 0.18 * sin(t * 0.21 + p)) }
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [w(0), 0], [1, 0],
                [0, w(1.3)], [w(2.1), w(0.7)], [1, w(2.9)],
                [0, 1], [w(3.3), 1], [1, 1],
            ], colors: [
                a.opacity(0.85), dark, b.opacity(0.7),
                dark, Color(hue: 0.04, saturation: 0.9, brightness: 0.25 + level * 0.25), dark,
                a.opacity(0.5), dark, b.opacity(0.9),
            ])
            .overlay(Color.black.opacity(0.18 - level * 0.1))
        }
        .ignoresSafeArea()
    }
}

/// A turntable drawn by hand. The record angle *is* the needle position, so scratches wobble exactly as heard.
struct Turntable: View {
    let booth: Booth
    let deck: Int

    var body: some View {
        TimelineView(.animation) { _ in
            let st = booth.core.decks[deck]
            let track = booth.tracks[deck]
            let angle = Angle.degrees((st.readPos / 44100 * 200).truncatingRemainder(dividingBy: 360))
            let touching: Bool = { switch st.mode { case .scratch, .brake, .spinback: return st.playing; default: return false } }()
            let rolling: Bool = { if case .roll = st.mode { return st.playing }; return false }()
            Canvas { ctx, size in
                let s = min(size.width, size.height)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = s / 2 * 0.94
                // plinth shadow + platter ring
                ctx.drawLayer { l in
                    l.addFilter(.shadow(color: .black.opacity(0.55), radius: 30, y: 18))
                    l.fill(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)), with: .color(Color(white: 0.07)))
                }
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)),
                           with: .linearGradient(Gradient(colors: [.white.opacity(0.28), .white.opacity(0.02), .white.opacity(0.16)]),
                                                 startPoint: CGPoint(x: c.x - R, y: c.y - R), endPoint: CGPoint(x: c.x + R, y: c.y + R)), lineWidth: 1.2)
                // vinyl + grooves (rotating)
                let vr = R * 0.93
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - vr, y: c.y - vr, width: 2 * vr, height: 2 * vr)), with: .color(Color(white: 0.035)))
                var grooves = Path()
                for k in stride(from: 0.38, to: 0.985, by: 0.012) {
                    let r = vr * k
                    grooves.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                }
                ctx.stroke(grooves, with: .color(.white.opacity(0.045)), lineWidth: 0.6)
                // static light sheen (reflections don't rotate)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - vr, y: c.y - vr, width: 2 * vr, height: 2 * vr)),
                         with: .conicGradient(Gradient(stops: [
                            .init(color: .clear, location: 0), .init(color: .white.opacity(0.10), location: 0.08),
                            .init(color: .clear, location: 0.2), .init(color: .clear, location: 0.5),
                            .init(color: .white.opacity(0.07), location: 0.58), .init(color: .clear, location: 0.7), .init(color: .clear, location: 1)]),
                            center: c, angle: .degrees(-30)))
                // label (rotating)
                var rot = ctx
                rot.translateBy(x: c.x, y: c.y)
                rot.rotate(by: angle)
                let lr = vr * 0.34
                let labelRect = CGRect(x: -lr, y: -lr, width: 2 * lr, height: 2 * lr)
                if let t = track {
                    rot.fill(Path(ellipseIn: labelRect), with: .linearGradient(Gradient(colors: [t.info.color, t.info.deepColor]),
                                                                               startPoint: CGPoint(x: -lr, y: -lr), endPoint: CGPoint(x: lr, y: lr)))
                    if let art = t.artwork {
                        rot.drawLayer { l in
                            l.clip(to: Path(ellipseIn: labelRect))
                            l.draw(Image(nsImage: art), in: labelRect)
                        }
                    } else {
                        let title = Text(t.info.title.uppercased()).font(.system(size: lr * 0.2, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.75))
                        rot.draw(title, in: CGRect(x: -lr * 0.8, y: -lr * 0.62, width: lr * 1.6, height: lr * 0.5))
                        let artist = Text(t.info.artist).font(.system(size: lr * 0.13, weight: .medium, design: .rounded)).foregroundStyle(.black.opacity(0.55))
                        rot.draw(artist, at: CGPoint(x: 0, y: lr * 0.42))
                    }
                    rot.fill(Path(roundedRect: CGRect(x: -2, y: lr * 0.62, width: 4, height: lr * 0.26), cornerRadius: 2), with: .color(.black.opacity(0.6)))
                } else {
                    rot.fill(Path(ellipseIn: labelRect), with: .color(Color(white: 0.12)))
                }
                rot.fill(Path(ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8)), with: .color(Color(white: 0.8)))
                // cue marker on the vinyl edge
                rot.stroke(Path { p in p.move(to: CGPoint(x: 0, y: -vr * 0.985)); p.addLine(to: CGPoint(x: 0, y: -vr * 0.82)) },
                           with: .color(.white.opacity(track == nil ? 0.1 : 0.85)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                // the AI's hand on the record: a glowing fingertip riding the rim
                if touching || rolling {
                    let a0 = angle.radians - .pi / 2
                    let fr = vr * 0.86
                    let p = CGPoint(x: c.x + fr * cos(a0), y: c.y + fr * sin(a0))
                    let col = Color(red: 1, green: 0.36, blue: 0.21)
                    ctx.drawLayer { l in
                        l.addFilter(.blur(radius: 14))
                        l.fill(Path(ellipseIn: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52)), with: .color(col.opacity(0.8)))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)), with: .color(col))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)), with: .color(col.opacity(0.5)), lineWidth: 1.5)
                }
                // tonearm
                let pivot = CGPoint(x: c.x + R * 0.98, y: c.y - R * 0.88)
                let needle = CGPoint(x: c.x + vr * 0.58, y: c.y - vr * 0.34)
                ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 16, y: pivot.y - 16, width: 32, height: 32)), with: .color(Color(white: 0.16)))
                ctx.stroke(Path(ellipseIn: CGRect(x: pivot.x - 16, y: pivot.y - 16, width: 32, height: 32)), with: .color(.white.opacity(0.18)), lineWidth: 1)
                ctx.stroke(Path { p in p.move(to: pivot); p.addQuadCurve(to: needle, control: CGPoint(x: pivot.x - 8, y: needle.y - 40)) },
                           with: .color(Color(white: 0.72)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                var head = Path(); head.addRoundedRect(in: CGRect(x: needle.x - 9, y: needle.y - 6, width: 20, height: 12), cornerSize: CGSize(width: 3, height: 3))
                ctx.fill(head, with: .color(Color(white: 0.85)))
            }
        }
    }
}

/// Scrolling waveform around the needle: bass red, mids green, highs blue, beat grid, playhead.
struct WaveStrip: View {
    let booth: Booth
    let deck: Int
    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { ctx, size in
                guard let t = booth.tracks[deck] else {
                    ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(.white.opacity(0.03)))
                    return
                }
                let st = booth.core.decks[deck]
                let a = t.analysis
                let binsPerSec = 44100.0 / Double(TrackAnalysis.hop)
                let center = st.readPos / 44100 * binsPerSec
                let span = 6.0 * binsPerSec                      // ±3 s
                let mid = size.height / 2
                let cols = Int(size.width / 2)
                for i in 0..<cols {
                    let bin = Int(center - span / 2 + Double(i) / Double(cols) * span)
                    guard bin >= 0, bin < a.wave.count else { continue }
                    let v = a.wave[bin]
                    let x = CGFloat(i) * 2
                    let hLow = CGFloat(v.x) * mid * 0.95, hMid = CGFloat(v.y) * mid * 0.8, hHigh = CGFloat(v.z) * mid * 0.6
                    ctx.fill(Path(CGRect(x: x, y: mid - hLow, width: 1.6, height: hLow * 2)), with: .color(Color(red: 1, green: 0.33, blue: 0.24).opacity(0.85)))
                    ctx.fill(Path(CGRect(x: x, y: mid - hMid, width: 1.6, height: hMid * 2)), with: .color(Color(red: 0.55, green: 1, blue: 0.55).opacity(0.55)))
                    ctx.fill(Path(CGRect(x: x, y: mid - hHigh, width: 1.6, height: hHigh * 2)), with: .color(Color(red: 0.45, green: 0.75, blue: 1).opacity(0.75)))
                }
                // beat grid
                let beatBins = 60 / a.bpm * binsPerSec
                let first = a.firstDownbeat * binsPerSec
                var k = floor((center - span / 2 - first) / beatBins)
                while true {
                    let bb = first + k * beatBins
                    if bb > center + span / 2 { break }
                    let x = (bb - (center - span / 2)) / span * size.width
                    let down = Int(k.rounded()) % 4 == 0
                    ctx.fill(Path(CGRect(x: x, y: 0, width: down ? 1.5 : 0.8, height: size.height)), with: .color(.white.opacity(down ? 0.35 : 0.12)))
                    k += 1
                }
                ctx.fill(Path(roundedRect: CGRect(x: size.width / 2 - 1, y: -2, width: 2, height: size.height + 4), cornerRadius: 1), with: .color(.white))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Whole-track overview with the hook marked and a playhead.
struct Overview: View {
    let booth: Booth
    let deck: Int
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
            Canvas { ctx, size in
                guard let t = booth.tracks[deck] else { return }
                let a = t.analysis
                let n = a.wave.count
                let cols = Int(size.width / 2)
                for i in 0..<cols {
                    let lo = i * n / cols, hi = max(lo + 1, (i + 1) * n / cols)
                    var m: Float = 0
                    for j in lo..<min(hi, n) { m = max(m, a.wave[j].x * 0.6 + a.wave[j].y * 0.3 + a.wave[j].z * 0.3) }
                    let h = CGFloat(min(1, m)) * size.height
                    ctx.fill(Path(CGRect(x: CGFloat(i) * 2, y: size.height - h, width: 1.4, height: h)), with: .color(.white.opacity(0.28)))
                }
                let dur = t.duration
                let hx = (a.firstDownbeat + Double(a.hookBar) * a.barSec) / dur * size.width
                ctx.fill(Path(CGRect(x: hx, y: 0, width: max(2, 8 * a.barSec / dur * size.width), height: size.height)), with: .color(t.info.color.opacity(0.35)))
                let px = booth.core.decks[deck].readPos / 44100 / dur * size.width
                ctx.fill(Path(CGRect(x: px - 1, y: -1, width: 2, height: size.height + 2)), with: .color(t.info.color))
            }
        }
    }
}
