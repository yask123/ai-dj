import SwiftUI
import UniformTypeIdentifiers

let ember = Color(red: 1, green: 0.353, blue: 0.212)

struct BoothView: View {
    @State private var booth = Booth()
    @State private var showCrate = true
    @State private var crateDeck = 1
    @State private var showKey = false
    @Namespace private var glass

    var body: some View {
        ZStack {
            AmbientBackground(booth: booth)
            VStack(spacing: 0) {
                TopBar(booth: booth, showKey: $showKey, showCrate: $showCrate)
                    .padding(.top, 14)
                HStack(alignment: .center, spacing: 26) {
                    DeckView(booth: booth, deck: 0) { crateDeck = 0; withAnimation(.smooth) { showCrate = true } }
                    MixerColumn(booth: booth)
                    DeckView(booth: booth, deck: 1) { crateDeck = 1; withAnimation(.smooth) { showCrate = true } }
                }
                .padding(.horizontal, 34)
                .frame(maxHeight: .infinity)
                Dock(booth: booth, showCrate: $showCrate)
                    .padding(.bottom, 20)
            }
            .padding(.trailing, showCrate ? 392 : 0)
            HStack {
                Spacer()
                if showCrate {
                    CratePanel(booth: booth, target: $crateDeck, close: { withAnimation(.smooth) { showCrate = false } })
                        .frame(width: 368)
                        .padding(.vertical, 16).padding(.trailing, 16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if let e = booth.error {
                VStack {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(2)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glassEffect(.regular.tint(ember.opacity(0.35)), in: .capsule)
                        .onTapGesture { booth.error = nil }
                        .task(id: e) { try? await Task.sleep(for: .seconds(6)); if booth.error == e { withAnimation { booth.error = nil } } }
                    Spacer()
                }
                .padding(.top, 84)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            VStack { Spacer(); HStack { Console(booth: booth).frame(width: 380); Spacer() } }
                .padding(.leading, 22).padding(.bottom, 104)
                .allowsHitTesting(false)
        }
        .frame(minWidth: 1180, minHeight: 780)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showKey) { KeySheet(booth: booth) }
        .onAppear { if booth.apiKey == nil { showKey = true } }
        .background(KeyCatcher(booth: booth))
    }
}

// MARK: - top bar: wordmark · Jev HUD · autopilot

struct TopBar: View {
    let booth: Booth
    @Binding var showKey: Bool
    @Binding var showCrate: Bool
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(ember)
                Text("Decks").font(.system(size: 21, weight: .semibold, design: .rounded))
            }
            .padding(.leading, 84)   // clear the traffic lights
            Spacer()
            JevHUD(booth: booth)
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button { withAnimation(.bouncy) { booth.autopilot.toggle() } } label: {
                        Label(booth.autopilot ? "Jev is DJing" : "You're DJing", systemImage: booth.autopilot ? "sparkles" : "hand.raised.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(booth.autopilot ? .regular.tint(ember.opacity(0.55)).interactive() : .regular.interactive(), in: .capsule)
                    Button { showKey = true } label: { Image(systemName: "key.fill").frame(width: 34, height: 34) }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                        .help("OpenRouter key for Jev")
                }
            }
            .padding(.trailing, 20)
        }
        .frame(height: 64)
    }
}

struct JevHUD: View {
    let booth: Booth
    @Namespace private var ns
    var body: some View {
        let d = booth.lastDecision
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    PulseDot(active: booth.thinking)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("JEV").font(.system(size: 13, weight: .heavy, design: .rounded)).kerning(1.5)
                        Text(booth.thinking ? "thinking…" : booth.playing ? "live · bar \(booth.bar)" : "ready")
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .glassEffectID("status", in: ns)

                if let d {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.byHuman ? "YOU" : "NEXT · BAR \(d.bar)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Image(systemName: d.move.symbol)
                                Text(d.move.title + (d.scratch.map { " · \($0)" } ?? ""))
                            }
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        }
                        if !d.probs.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(d.probs.prefix(3), id: \.0) { name, p in
                                    HStack(spacing: 6) {
                                        Capsule().fill(name == d.move.rawValue ? ember : .white.opacity(0.35))
                                            .frame(width: max(3, 90 * p), height: 4)
                                            .frame(width: 90, alignment: .leading)
                                        Text(Move(rawValue: name)?.title ?? name).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(width: 180, alignment: .leading)
                        }
                        if d.ms > 0 {
                            Text(d.late ? "LATE" : "\(Int(d.ms)) ms")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(d.late ? ember : .white.opacity(0.1)))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("decision", in: ns)
                    .id(d.id)
                    .transition(.blurReplace)
                }
            }
        }
        .animation(.bouncy(duration: 0.45), value: d?.id)
    }
}

struct PulseDot: View {
    var active: Bool
    var body: some View {
        TimelineView(.animation(paused: !active)) { tl in
            let p = active ? 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 12) : 0
            Circle().fill(active ? ember : Color.green.opacity(0.9))
                .frame(width: 9, height: 9)
                .shadow(color: (active ? ember : .green).opacity(0.9), radius: 4 + 6 * p)
        }
    }
}

// MARK: - a deck

struct DeckView: View {
    let booth: Booth
    let deck: Int
    var openCrate: () -> Void
    @State private var dropHover = false

    var body: some View {
        let t = booth.tracks[deck]
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(deck == 0 ? "A" : "B").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(t?.info.color ?? .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t?.info.title ?? (booth.loadingText[deck] != nil ? "Cueing up…" : "Empty deck"))
                        .font(.system(size: 19, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(t.map { "\($0.info.artist)" } ?? "Drop a song here or pick one from the crate")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let t {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f", t.analysis.bpm)).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(t.info.license ?? "your file").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            WaveStrip(booth: booth, deck: deck).frame(height: 64)
                .overlay(alignment: .bottomTrailing) {
                    if t != nil {
                        HStack(spacing: 2) {
                            Button { booth.nudgeGrid(deck, beats: -1) } label: { Image(systemName: "chevron.left") }
                            Text("1").font(.system(size: 11, weight: .bold, design: .rounded)).frame(width: 14)
                            Button { booth.nudgeGrid(deck, beats: 1) } label: { Image(systemName: "chevron.right") }
                        }
                        .font(.system(size: 10, weight: .bold)).buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(6)
                        .help("Move beat 1 of the bar grid")
                    }
                }
            Overview(booth: booth, deck: deck).frame(height: 18).opacity(t == nil ? 0 : 1)
            ZStack {
                Turntable(booth: booth, deck: deck)
                    .aspectRatio(1, contentMode: .fit)
                if let s = booth.loadingText[deck] {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text(s).font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .padding(22).glassEffect(.regular, in: .rect(cornerRadius: 22))
                } else if t == nil {
                    Button(action: openCrate) {
                        Label("Load a record", systemImage: "plus").font(.system(size: 14, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 30).stroke(ember.opacity(dropHover ? 0.8 : 0), lineWidth: 2))
            ModeLine(booth: booth, deck: deck)
        }
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in booth.load(await Loader.localInfo(url), deck: deck) }
            }
            return true
        }
    }
}

struct ModeLine: View {
    let booth: Booth
    let deck: Int
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            let st = booth.core.decks[deck]
            let (txt, hot): (String, Bool) = {
                guard st.playing else { return (booth.tracks[deck] == nil ? " " : "CUED", false) }
                switch st.mode {
                case .play: return ("PLAYING", false)
                case .scratch(let s, _, _, _): return ("SCRATCH · \(s.name.uppercased())", true)
                case .roll(let size, _, _):
                    let beats = size / (44100 * 60 / st.trackBPM)
                    return (beats > 0.9 ? "LOOP · 1 BEAT" : "ROLL · 1/\(Int((1 / beats).rounded()))", true)
                case .brake: return ("BRAKE", true)
                case .spinback: return ("SPINBACK", true)
                case .mute: return ("CUT", true)
                }
            }()
            Text(txt).font(.system(size: 12, weight: .semibold, design: .monospaced)).kerning(1.2)
                .foregroundStyle(hot ? ember : .secondary)
                .contentTransition(.opacity)
        }
        .frame(height: 16)
    }
}

// MARK: - mixer

struct MixerColumn: View {
    let booth: Booth
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let core = booth.core
            VStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text(String(format: "%.1f", core.masterBPM)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("BPM").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                }
                BeatDots(booth: booth)
                HStack(alignment: .top, spacing: 18) {
                    ForEach(0..<2, id: \.self) { d in
                        let st = core.decks[d]
                        VStack(spacing: 12) {
                            Knob(label: "HI", value: st.high.v, range: 0...1.4) { v in booth.core.schedule([DJEvent(at: booth.core.now, deck: d, action: .high(v, ramp: 400))]) }
                            Knob(label: "MID", value: st.mid.v, range: 0...1.4) { v in booth.core.schedule([DJEvent(at: booth.core.now, deck: d, action: .mid(v, ramp: 400))]) }
                            Knob(label: "LOW", value: st.low.v, range: 0...1.4) { v in booth.core.schedule([DJEvent(at: booth.core.now, deck: d, action: .low(v, ramp: 400))]) }
                            Knob(label: "FILTER", value: st.filter.v, range: -1...1, bipolar: true) { v in booth.core.schedule([DJEvent(at: booth.core.now, deck: d, action: .filter(v, ramp: 400))]) }
                            Circle().fill(st.echo.v > 0.05 ? ember : .white.opacity(0.12)).frame(width: 7, height: 7)
                                .overlay(Text("ECHO").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary).fixedSize().offset(y: 11))
                                .padding(.bottom, 8)
                            LevelMeter(level: st.playing ? min(1, sqrt(st.rms) * 3.2 * st.gain.v) : 0, color: booth.tracks[d]?.info.color ?? .white)
                                .frame(width: 6, height: 70)
                        }
                    }
                }
            }
            .padding(.vertical, 22).padding(.horizontal, 18)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
        }
        .frame(width: 150)
    }
}

struct BeatDots: View {
    let booth: Booth
    var body: some View {
        let beat = booth.playing ? Int(Double(booth.core.now) / booth.core.samplesPerBeat) % 4 : -1
        HStack(spacing: 7) {
            ForEach(0..<4, id: \.self) { k in
                Circle().fill(k == beat ? (k == 0 ? ember : .white) : .white.opacity(0.15)).frame(width: 7, height: 7)
            }
        }
    }
}

struct LevelMeter: View {
    var level: Float
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [color, color.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                    .frame(height: g.size.height * CGFloat(level))
            }
        }
    }
}

struct Knob: View {
    var label: String
    var value: Float
    var range: ClosedRange<Float>
    var bipolar = false
    var set: (Float) -> Void
    @State private var dragStart: Float?

    var body: some View {
        let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        let zero = bipolar ? 0.5 : CGFloat((1 - range.lowerBound) / (range.upperBound - range.lowerBound))
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.white.opacity(0.06))
                Circle().trim(from: 0.125, to: 0.875).stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(90))
                Circle().trim(from: 0.125 + 0.75 * min(zero, frac), to: 0.125 + 0.75 * max(zero, frac))
                    .stroke(abs(frac - zero) > 0.02 ? ember : .white.opacity(0.3), style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(90))
                Capsule().fill(.white).frame(width: 2.5, height: 8).offset(y: -8)
                    .rotationEffect(.degrees(-135 + 270 * Double(frac)))
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let s = dragStart ?? value
                    if dragStart == nil { dragStart = value }
                    let v = s + Float(-g.translation.height / 120) * (range.upperBound - range.lowerBound)
                    set(min(range.upperBound, max(range.lowerBound, v)))
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { set(bipolar ? 0 : 1) }
            Text(label).font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - dock: transport · crossfader · moves

struct Dock: View {
    let booth: Booth
    @Binding var showCrate: Bool
    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button { withAnimation(.bouncy) { booth.togglePlay() } } label: {
                    Image(systemName: booth.playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold)).frame(width: 54, height: 54)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(ember.opacity(booth.playing ? 0.35 : 0.8)).interactive(), in: .circle)
                .disabled(booth.tracks[0] == nil && booth.tracks[1] == nil)
                .keyboardShortcut(.space, modifiers: [])

                if booth.playing {
                    Button("End set") { booth.endSet() }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .buttonStyle(.plain).padding(.horizontal, 14).frame(height: 40)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }

                Crossfader(booth: booth)
                    .frame(width: 230, height: 40)
                    .padding(.horizontal, 16)
                    .glassEffect(.regular, in: .capsule)

                HStack(spacing: 4) {
                    ForEach(Move.transitions + [.scratchFill, .rollFill, .echoThrow, .filterDip]) { m in
                        Button { booth.perform(m) } label: {
                            Image(systemName: m.symbol).font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .help(m.title + (booth.autopilot ? " (take over for a bar)" : ""))
                        .disabled(!booth.playing)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .glassEffect(.regular, in: .capsule)

                Button { withAnimation(.smooth) { showCrate.toggle() } } label: {
                    Image(systemName: "square.stack.3d.down.forward.fill").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                .help("Crate")
            }
        }
    }
}

struct Crossfader: View {
    let booth: Booth
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let c = booth.core
            // show where the sound really is: manual fader, or the AI's deck gains
            let a = c.decks[0].playing ? c.decks[0].gain.v * c.decks[0].env : 0
            let b = c.decks[1].playing ? c.decks[1].gain.v * c.decks[1].env : 0
            let auto = a + b > 0.01 ? CGFloat((b - a) / (a + b)) : 0
            let pos = booth.autopilot && booth.playing ? auto : CGFloat(booth.crossfader)
            GeometryReader { g in
                let w = g.size.width - 30
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1)).frame(height: 4).padding(.horizontal, 15)
                    HStack { Text("A"); Spacer(); Text("B") }.font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 30, height: 22)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .offset(x: (pos + 1) / 2 * w)
                        .animation(.interactiveSpring(duration: 0.06), value: pos)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    booth.crossfader = Float(max(-1, min(1, (v.location.x - 15) / w * 2 - 1)))
                })
                .onTapGesture(count: 2) { booth.crossfader = 0 }
            }
        }
    }
}

// MARK: - console: the tool calls

struct Console: View {
    let booth: Booth
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(booth.log.suffix(7).enumerated()), id: \.element.id) { i, l in
                HStack(spacing: 8) {
                    Text(l.stamp).foregroundStyle(.white.opacity(0.3))
                    Text("› " + l.text).foregroundStyle(l.brain ? (l.text.hasPrefix("jev.") ? ember : .white.opacity(0.9)) : .white.opacity(0.55))
                        .lineLimit(1)
                }
                .opacity(0.35 + 0.65 * Double(i + 1) / Double(min(7, booth.log.count)))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .animation(.smooth(duration: 0.25), value: booth.log.count)
    }
}

// MARK: - keyboard: 1-7 transitions, Q/W/E/R fills

struct KeyCatcher: View {
    let booth: Booth
    var body: some View {
        let keys: [(KeyEquivalent, Move)] = [("1", .scratchIn), ("2", .chopCut), ("3", .echoOut), ("4", .spinback), ("5", .brake), ("6", .rollBuild),
                                             ("7", .dropGap), ("8", .blend), ("q", .scratchFill), ("w", .rollFill), ("e", .echoThrow), ("r", .filterDip)]
        ZStack {
            ForEach(keys, id: \.1) { k, m in
                Button("") { booth.perform(m) }.keyboardShortcut(k, modifiers: []).opacity(0)
            }
        }
        .frame(width: 0, height: 0)
    }
}

// MARK: - key sheet

struct KeySheet: View {
    let booth: Booth
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Give Jev the decks", systemImage: "sparkles").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Jev (TypeSafe) decides every move live in ~150 ms. It's served through OpenRouter; paste an OpenRouter key. It's stored in your Keychain.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("sk-or-…", text: $key).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            HStack {
                Link("Get a key ↗", destination: URL(string: "https://openrouter.ai/keys")!).font(.system(size: 12))
                Spacer()
                Button("Later") { dismiss() }.buttonStyle(.glass)
                Button("Save") { Keychain.set("openrouter", key); booth.apiKey = key; dismiss() }
                    .buttonStyle(.glassProminent).tint(ember).disabled(key.count < 10)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { key = booth.apiKey ?? "" }
    }
}
