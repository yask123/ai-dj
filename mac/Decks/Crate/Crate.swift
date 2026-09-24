import AVFoundation
import AppKit
import Foundation

enum TrackSource: Hashable, Sendable {
    case ccmixter(URL)   // Creative Commons stream
    case local(URL)      // the user's own DRM-free file
}

struct TrackInfo: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var source: TrackSource
    var bpmHint: Double?
    var license: String?
    var page: URL?
    var duration: Double?

    var hue: Double {   // a stable colour per track for labels + ambient light
        var h: UInt64 = 1469598103934665603
        for b in (title + artist).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 360) / 360
    }
    var isFree: Bool { if case .ccmixter = source { return true }; return false }
}

final class LoadedTrack: @unchecked Sendable {
    let info: TrackInfo
    let pcm: PCMBuffer
    var analysis: TrackAnalysis
    let artwork: NSImage?
    init(info: TrackInfo, pcm: PCMBuffer, analysis: TrackAnalysis, artwork: NSImage?) {
        self.info = info; self.pcm = pcm; self.analysis = analysis; self.artwork = artwork
    }
    var duration: Double { Double(pcm.count) / 44100 }
}

enum Loader {
    /// Stream (remote) or open (local), decode to PCM in memory, analyse. Nothing is written to the user's library.
    static func load(_ info: TrackInfo, progress: @Sendable @escaping (String) -> Void) async throws -> LoadedTrack {
        var fileURL: URL
        var tempToDelete: URL?
        switch info.source {
        case .local(let u):
            fileURL = u
        case .ccmixter(let u):
            progress("streaming")
            var req = URLRequest(url: u)
            req.setValue("https://ccmixter.org/", forHTTPHeaderField: "Referer")   // ccMixter blocks hotlinks without it
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode >= 300 || !(h.mimeType ?? "audio").hasPrefix("audio") {
                throw NSError(domain: "Decks", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "ccMixter refused the stream (HTTP \(h.statusCode))"])
            }
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (u.pathExtension.isEmpty ? "mp3" : u.pathExtension))
            try FileManager.default.moveItem(at: tmp, to: dst)
            fileURL = dst; tempToDelete = dst
        }
        defer { if let t = tempToDelete { try? FileManager.default.removeItem(at: t) } }
        progress("decoding")
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        let (l, r) = try Decoder.decode(fileURL)
        var art: NSImage?
        if case .local = info.source {
            let asset = AVURLAsset(url: fileURL)
            if let items = try? await asset.load(.commonMetadata),
               let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await item.load(.dataValue) { art = NSImage(data: data) }
        }
        progress("finding the beat")
        let a = Analyzer.analyze(l: l, r: r, bpmHint: info.bpmHint)
        return LoadedTrack(info: info, pcm: PCMBuffer(l: l, r: r), analysis: a, artwork: art)
    }

    static func localInfo(_ url: URL) async -> TrackInfo {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent, artist = "My music"
        if let items = try? await asset.load(.commonMetadata) {
            if let t = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle).first,
               let s = try? await t.load(.stringValue) { title = s }
            if let a = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtist).first,
               let s = try? await a.load(.stringValue) { artist = s }
        }
        let dur = try? await asset.load(.duration).seconds
        return TrackInfo(id: url.absoluteString, title: title, artist: artist, source: .local(url), duration: dur)
    }
}

/// ccMixter: a large library of Creative Commons remixes, instrumentals and a cappellas, with a keyless API.
/// We only request CC BY (attribution) tracks, which allow remixing; the app always shows the credit.
enum CCMixter {
    static func search(_ q: String, bpm: ClosedRange<Int>? = nil) async throws -> [TrackInfo] {
        var c = URLComponents(string: "https://ccmixter.org/api/query")!
        var items = [URLQueryItem(name: "f", value: "json"), URLQueryItem(name: "lic", value: "by"),
                     URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "sort", value: "rank")]
        if !q.trimmingCharacters(in: .whitespaces).isEmpty { items.append(URLQueryItem(name: "search", value: q)) }
        if let bpm {
            let lo = bpm.lowerBound / 5 * 5
            items.append(URLQueryItem(name: "reqtags", value: "bpm_\(lo)_\(lo + 5)"))
        }
        c.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { t in
            guard let name = t["upload_name"] as? String, let user = t["user_name"] as? String,
                  let files = t["files"] as? [[String: Any]],
                  let f = files.first(where: { (($0["file_format_info"] as? [String: Any])?["mime_type"] as? String) == "audio/mpeg" }),
                  let dl = f["download_url"] as? String, let url = URL(string: dl) else { return nil }
            let extra = t["upload_extra"] as? [String: Any]
            let bpmAny = extra?["bpm"]
            let bpm = (bpmAny as? Double) ?? (bpmAny as? Int).map(Double.init) ?? Double(String(describing: bpmAny ?? "").prefix { $0.isNumber || $0 == "." })
            let page = (t["file_page_url"] as? String).flatMap(URL.init(string:))
            return TrackInfo(id: dl, title: name, artist: user, source: .ccmixter(url), bpmHint: bpm,
                             license: (t["license_name"] as? String).map { "CC " + $0 }, page: page)
        }
    }
}
