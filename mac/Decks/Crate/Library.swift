import Foundation
import iTunesLibrary

/// Songs already on this Mac, from the places people keep them. Only real, unprotected files are playable:
/// Apple Music subscription downloads and Spotify's cache are DRM-encrypted and are never touched.
enum LocalLibrary {
    static let audioExt: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "alac"]

    struct Result: Sendable { var tracks: [TrackInfo]; var locked: Int; var note: String? }

    // MARK: Apple Music (Music.app library)
    static func appleMusic() -> Result {
        do {
            let lib = try ITLibrary(apiVersion: "1.1")
            var out: [TrackInfo] = [], locked = 0
            for item in lib.allMediaItems where item.mediaKind == .kindSong {
                guard let url = item.location, item.locationType == .file, FileManager.default.fileExists(atPath: url.path) else {
                    if item.isDRMProtected || item.isCloud { locked += 1 }
                    continue
                }
                if item.isDRMProtected || url.pathExtension.lowercased() == "m4p" { locked += 1; continue }
                var title = item.title, artist = item.artist?.name ?? item.album.albumArtist ?? ""
                if artist.isEmpty, title.contains(" - ") { let p = title.components(separatedBy: " - "); artist = p[0]; title = p.dropFirst().joined(separator: " - ") }
                out.append(TrackInfo(id: url.absoluteString, title: title, artist: artist.isEmpty ? "Unknown artist" : artist,
                                     source: .local(url), bpmHint: item.beatsPerMinute > 0 ? Double(item.beatsPerMinute) : nil,
                                     license: "Apple Music library", duration: Double(item.totalTime) / 1000))
            }
            return Result(tracks: out.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }, locked: locked,
                          note: locked > 0 ? "\(locked) songs are Apple Music subscription downloads or cloud-only: DRM-protected, so no app can mix them." : nil)
        } catch {
            return Result(tracks: [], locked: 0, note: "Couldn't open your Music library (\(error.localizedDescription)). Allow Decks under System Settings › Privacy & Security › Media & Apple Music.")
        }
    }

    // MARK: Spotify Local Files (the files Spotify plays from your Mac; its streams are encrypted and off-limits)
    static func spotifyLocalFiles() -> Result {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Spotify/Users")
        guard let users = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return Result(tracks: [], locked: 0, note: "Spotify isn't installed, or has no Local Files yet.")
        }
        var paths = Set<String>()
        for u in users {
            guard let data = try? Data(contentsOf: u.appendingPathComponent("local-files.bnk")) else { continue }
            // the index is a binary blob; pull out absolute paths to audio files
            let text = String(decoding: data.map { (32...126).contains($0) ? $0 : 10 }, as: UTF8.self)
            for line in text.split(separator: "\n") {
                guard let slash = line.firstIndex(of: "/") else { continue }
                let p = String(line[slash...])
                if audioExt.contains((p as NSString).pathExtension.lowercased()), !p.contains(".app/"), FileManager.default.fileExists(atPath: p) { paths.insert(p) }
            }
        }
        var seen = Set<String>(), out: [TrackInfo] = []
        for p in paths.sorted() {
            let name = (p as NSString).lastPathComponent
            if seen.insert(name).inserted { out.append(fileInfo(URL(fileURLWithPath: p), license: "Spotify local file")) }
        }
        return Result(tracks: out, locked: 0, note: out.isEmpty ? "No Spotify Local Files found. Spotify's own streams and downloads are encrypted, so only songs you added as Local Files can be mixed." : "Spotify's streamed songs are encrypted; these are the Local Files it plays from your Mac.")
    }

    // MARK: Folders
    static var folders: [URL] {
        get {
            let saved = (UserDefaults.standard.stringArray(forKey: "folders") ?? []).map { URL(fileURLWithPath: $0) }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return [home.appendingPathComponent("Music"), home.appendingPathComponent("Downloads")] + saved
        }
    }
    static func addFolder(_ url: URL) {
        var saved = UserDefaults.standard.stringArray(forKey: "folders") ?? []
        if !saved.contains(url.path) { saved.append(url.path) }
        UserDefaults.standard.set(saved, forKey: "folders")
    }

    static func scanFolders() -> Result {
        var out: [TrackInfo] = [], seen = Set<String>()
        for root in folders {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isPackageKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                if en.level > 5 { en.skipDescendants(); continue }
                guard audioExt.contains(url.pathExtension.lowercased()), !url.path.contains("/Contents/"), seen.insert(url.path).inserted else { continue }
                out.append(fileInfo(url, license: "your file"))
                if out.count > 2000 { break }
            }
        }
        return Result(tracks: out, locked: 0, note: nil)
    }

    /// Title from the file name, or from a sidecar `<name>.info.json` (e.g. left by the ai-dj prep tools).
    static func fileInfo(_ url: URL, license: String) -> TrackInfo {
        var title = url.deletingPathExtension().lastPathComponent, artist = url.deletingLastPathComponent().lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        for side in [url.deletingLastPathComponent().appendingPathComponent("\(stem).info.json"),
                     url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("library/\(stem).info.json")] {
            if let d = try? Data(contentsOf: side), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = j["title"] as? String {
                title = t; artist = (j["artist"] as? String) ?? (j["channel"] as? String) ?? artist
            }
        }
        let crate = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("crate.json")
        if let d = try? Data(contentsOf: crate), let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]],
           let t = j[stem]?["title"] as? String {
            title = t.replacingOccurrences(of: " – ", with: " - ")
            artist = url.deletingLastPathComponent().lastPathComponent
        }
        // YouTube-style "Artist - Title (Official Video)" → clean artist + title
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(official|video|audio|lyric|explicit|visuali[sz]er|hd|4k|remaster)[^\)\]]*[\)\]]"#,
                                           with: "", options: [.regularExpression, .caseInsensitive])
        if let r = title.range(of: " | ") { title = String(title[..<r.lowerBound]) }
        if title.contains(" - ") {
            let parts = title.components(separatedBy: " - ")
            artist = parts[0]; title = parts.dropFirst().joined(separator: " - ")
        }
        title = title.trimmingCharacters(in: .whitespaces)
        title = title.replacingOccurrences(of: "_", with: " ")
        return TrackInfo(id: url.absoluteString, title: title.prefix(1).uppercased() + title.dropFirst(), artist: artist, source: .local(url), license: license)
    }
}
