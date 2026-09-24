import Foundation

/// "Find a song": type a name or paste a Spotify link. Spotify is only used to read the title/artist (its audio is
/// encrypted and never touched); the audio comes from YouTube via yt-dlp, cached locally. Personal use.
enum SongFinder {
    static let cache: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Decks/youtube", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static var ytdlp: String? {
        ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum FindError: LocalizedError {
        case noYtdlp, failed(String)
        var errorDescription: String? {
            switch self {
            case .noYtdlp: "Finding songs needs yt-dlp. Install it with: brew install yt-dlp ffmpeg"
            case .failed(let s): s
            }
        }
    }

    /// Spotify track link → "Artist Title"; anything else is used as-is.
    static func resolve(_ input: String) async -> (query: String, label: String?) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), url.host?.contains("spotify.com") == true, url.path.contains("/track/") else { return (s, nil) }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req), let html = String(data: data, encoding: .utf8) else { return (s, nil) }
        func meta(_ key: String) -> String? {
            guard let r = html.range(of: "\(key)\" content=\"") else { return nil }
            let rest = html[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end]).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#x27;", with: "'")
        }
        guard let title = meta("og:title") else { return (s, nil) }
        let artist = meta("music:musician_description")?.components(separatedBy: ",").first
            ?? meta("og:description")?.components(separatedBy: " · ").first ?? ""
        let clean = title.replacingOccurrences(of: #"\s*\((feat|with)[^)]*\)"#, with: "", options: .regularExpression)
        return ("\(artist) \(clean) audio", "\(clean) — \(artist)")
    }

    private static func run(_ args: [String]) async throws -> Data {
        guard let bin = ytdlp else { throw FindError.noYtdlp }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")   // GUI apps get a bare PATH; yt-dlp needs ffmpeg
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.terminationHandler = { proc in
                let o = out.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 { cont.resume(returning: o) }
                else {
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(throwing: FindError.failed("yt-dlp: " + (e.split(separator: "\n").last.map(String.init) ?? "failed")))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    static func search(_ input: String) async throws -> (tracks: [TrackInfo], label: String?) {
        let (q, label) = await resolve(input)
        let data = try await run(["--flat-playlist", "-J", "--no-warnings", "ytsearch8:\(q)"])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = obj["entries"] as? [[String: Any]] else { return ([], label) }
        let tracks: [TrackInfo] = entries.compactMap { e in
            guard let id = e["id"] as? String, let raw = e["title"] as? String else { return nil }
            let dur = (e["duration"] as? Double) ?? (e["duration"] as? Int).map(Double.init)
            if let d = dur, d > 660 || d < 60 { return nil }               // skip hour-long mixes and shorts
            var title = raw.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(official|video|audio|lyric|explicit|visuali[sz]er|hd|4k)[^\)\]]*[\)\]]"#,
                                                 with: "", options: [.regularExpression, .caseInsensitive])
            var artist = (e["channel"] as? String ?? e["uploader"] as? String ?? "YouTube").replacingOccurrences(of: " - Topic", with: "")
            if title.contains(" - ") { let p = title.components(separatedBy: " - "); artist = p[0]; title = p.dropFirst().joined(separator: " - ") }
            return TrackInfo(id: "yt:" + id, title: title.trimmingCharacters(in: .whitespaces), artist: artist, source: .youtube(id),
                             license: "YouTube · personal use", duration: dur,
                             thumb: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"))
        }
        return (tracks, label)
    }

    /// Audio file for a video id (cached).
    static func fetch(_ id: String) async throws -> URL {
        if let hit = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first(where: { $0.deletingPathExtension().lastPathComponent == id }) {
            return hit
        }
        _ = try await run(["-q", "--no-warnings", "--no-playlist", "-f", "bestaudio[ext=m4a]/bestaudio", "-x", "--audio-format", "m4a",
                           "-o", cache.appendingPathComponent("%(id)s.%(ext)s").path, "https://www.youtube.com/watch?v=\(id)"])
        guard let f = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first(where: { $0.deletingPathExtension().lastPathComponent == id }) else {
            throw FindError.failed("Download finished but no audio file appeared")
        }
        return f
    }
}
