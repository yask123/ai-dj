import SwiftUI
import UniformTypeIdentifiers

struct CratePanel: View {
    let booth: Booth
    @Binding var target: Int
    var close: () -> Void
    @State private var tab = 0
    @State private var query = ""
    @State private var matchBPM = false
    @State private var results: [TrackInfo] = []
    @State private var mine: [TrackInfo] = []
    @State private var busy = false
    @State private var importing = false
    @State private var addingFolder = false
    @State private var source = 0            // 0 Apple Music · 1 Spotify · 2 Folders
    @State private var note: String?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Crate").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Picker("", selection: $target) { Text("→ A").tag(0); Text("→ B").tag(1) }
                    .pickerStyle(.segmented).frame(width: 110).help("Which deck new records load onto")
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
            }
            Picker("", selection: $tab) {
                Label("Free crate", systemImage: "globe").tag(0)
                Label("My music", systemImage: "music.note.house").tag(1)
            }
            .pickerStyle(.segmented)

            if tab == 0 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("house, funk, a cappella…", text: $query).textFieldStyle(.plain).onSubmit { search() }
                    Toggle(isOn: $matchBPM) { Text("≈ BPM").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                        .toggleStyle(.button).controlSize(.small)
                        .onChange(of: matchBPM) { search() }
                        .help("Only tracks near the current tempo")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                list(results)
                Text("Streamed from ccMixter. Every track here is Creative Commons Attribution: free to remix, credit shown on the deck.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("", selection: $source) {
                    Label("Music", systemImage: "music.note").tag(0)
                    Label("Spotify", systemImage: "antenna.radiowaves.left.and.right").tag(1)
                    Label("Folders", systemImage: "folder").tag(2)
                }
                .pickerStyle(.segmented)
                .onChange(of: source) { scanLocal() }
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("filter", text: $filter).textFieldStyle(.plain)
                    Menu {
                        Button("Add songs…") { importing = true }
                        Button("Add a folder…") { addingFolder = true }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                list(filter.isEmpty ? mine : mine.filter { ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(filter) })
                Text(note ?? "Unprotected files on this Mac. Streaming-service downloads are DRM-encrypted and can't be mixed by any app.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .task { if results.isEmpty { search() } }
        .onChange(of: tab) { if tab == 1 && mine.isEmpty { scanLocal() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task { for u in urls { _ = u.startAccessingSecurityScopedResource(); mine.insert(await Loader.localInfo(u), at: 0) } }
        }
        .background(EmptyView().fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { r in
            guard case .success(let u) = r else { return }
            LocalLibrary.addFolder(u); source = 2; scanLocal()
        })
    }

    @ViewBuilder private func list(_ items: [TrackInfo]) -> some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if busy { ProgressView().padding(30) }
                ForEach(items) { t in
                    Row(t: t, target: target, load: { d in
                        booth.load(t, deck: d)
                        if booth.tracks[1 - d] == nil && booth.loadingText[1 - d] == nil { target = 1 - d }
                    })
                }
                if !busy && items.isEmpty {
                    Text(tab == 0 ? "Nothing found." : "No songs yet.").font(.system(size: 12)).foregroundStyle(.secondary).padding(30)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private func scanLocal() {
        busy = true; mine = []; note = nil
        let src = source
        Task.detached(priority: .userInitiated) {
            let r = src == 0 ? LocalLibrary.appleMusic() : src == 1 ? LocalLibrary.spotifyLocalFiles() : LocalLibrary.scanFolders()
            await MainActor.run { mine = r.tracks; note = r.note; busy = false }
        }
    }

    private func search() {
        busy = true
        let bpm = matchBPM && booth.tracks.contains(where: { $0 != nil }) ? Int(booth.bpm) : nil
        Task {
            results = (try? await CCMixter.search(query, bpm: bpm.map { ($0 - 2)...($0 + 2) })) ?? []
            busy = false
        }
    }
}

private struct Row: View {
    let t: TrackInfo
    var target: Int
    var load: (Int) -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [t.color, t.deepColor], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: t.isFree ? "waveform" : "music.note").font(.system(size: 14, weight: .semibold)).foregroundStyle(.black.opacity(0.55)))
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(t.artist).lineLimit(1)
                    if let b = t.bpmHint { Text("· \(Int(b)) bpm").monospacedDigit() }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { d in
                        Button(d == 0 ? "A" : "B") { load(d) }
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .buttonStyle(.glass).controlSize(.small)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { load(target) }
        .help("Click to load onto deck \(target == 0 ? "A" : "B")")
    }
}
