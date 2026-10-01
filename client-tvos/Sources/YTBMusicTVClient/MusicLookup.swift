import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MusicArtworkResult {
    var still: URL?
    var motion: URL?
}

struct LRCLIBRecord: Decodable {
    var trackName: String?
    var artistName: String?
    var duration: Double?
    var instrumental: Bool?
    var syncedLyrics: String?
    var plainLyrics: String?
}

enum MusicLookup {
    static func cleaned(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)\s*\([^)]*(official|video|audio|lyrics?|visualizer|4k|hd)[^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*\[[^\]]*(official|video|audio|lyrics?|visualizer|4k|hd)[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*-\s*Topic$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 9)
        request.setValue("YTBMusicTV-Custom/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 16 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        try Task.checkCancellation()
        return data
    }

    static func query(_ base: String, _ parameters: [String: String]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    static func normalized(_ value: String) -> String {
        cleaned(value).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func primaryArtist(_ value: String) -> String {
        let text = cleaned(value)
        if let range = text.range(of: #"(?i)\s*(?:,|&|;| feat\.? | featuring | ft\.? )\s*"#, options: .regularExpression) {
            return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func bestLyrics(_ records: [LRCLIBRecord], title: String, artist: String, duration: Double) -> MusicLyrics {
        let compatible = records.filter { record in
            normalized(record.trackName ?? "") == normalized(title) &&
            (normalized(record.artistName ?? "") == normalized(artist) ||
             normalized(primaryArtist(record.artistName ?? "")) == normalized(primaryArtist(artist))) &&
            (duration <= 0 || record.duration == nil || abs((record.duration ?? duration) - duration) <= 12)
        }
        let sorted = compatible.sorted {
            let left = MusicLyrics.parse(synced: $0.syncedLyrics, plain: $0.plainLyrics, instrumental: $0.instrumental == true)
            let right = MusicLyrics.parse(synced: $1.syncedLyrics, plain: $1.plainLyrics, instrumental: $1.instrumental == true)
            if left.synchronized != right.synchronized { return left.synchronized }
            return abs(($0.duration ?? duration) - duration) < abs(($1.duration ?? duration) - duration)
        }
        guard let record = sorted.first else { return MusicLyrics() }
        return MusicLyrics.parse(synced: record.syncedLyrics, plain: record.plainLyrics, instrumental: record.instrumental == true)
    }

    static func lyrics(for media: MediaItem) async -> MusicLyrics {
        let title = cleaned(media.title), artist = cleaned(media.artist)
        guard !title.isEmpty, !artist.isEmpty else { return MusicLyrics() }
        var fallback = MusicLyrics()
        var exact = ["track_name": title, "artist_name": artist]
        if let album = media.album, !album.isEmpty { exact["album_name"] = cleaned(album) }
        if media.durationMs > 0 { exact["duration"] = String(Double(media.durationMs) / 1000) }
        if let url = query("https://lrclib.net/api/get", exact),
           let data = try? await fetch(url), let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) {
            fallback = MusicLyrics.parse(synced: record.syncedLyrics, plain: record.plainLyrics, instrumental: record.instrumental == true)
            if fallback.synchronized || fallback.instrumental { return fallback }
        }
        let artists = artist == primaryArtist(artist) ? [artist] : [artist, primaryArtist(artist)]
        for searchArtist in artists {
            guard !Task.isCancelled else { return fallback }
            try? await Task.sleep(for: .milliseconds(250))
            if let url = query("https://lrclib.net/api/search", ["track_name": title, "artist_name": searchArtist]),
               let data = try? await fetch(url), let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data) {
                let result = bestLyrics(records, title: title, artist: artist, duration: Double(media.durationMs) / 1000)
                if result.synchronized { return result }
                if fallback.lines.isEmpty { fallback = result }
            }
        }
        // LyricsPlus exposes millisecond line/word timestamps. Keep line timing
        // intact rather than displaying plain lyrics when another source has sync.
        var parameters = ["title": title, "artist": artist]
        if let album = media.album, !album.isEmpty { parameters["album"] = cleaned(album) }
        if media.durationMs > 0 { parameters["duration"] = String(Double(media.durationMs) / 1000) }
        for host in ["https://lyricsplus.binimum.org", "https://lyricsplus.prjktla.workers.dev"] {
            guard !Task.isCancelled else { return fallback }
            if let url = query(host + "/v2/lyrics/get", parameters), let data = try? await fetch(url) {
                let result = parseLyricsPlus(data)
                if result.synchronized { return result }
                if fallback.lines.isEmpty { fallback = result }
            }
        }
        return fallback
    }

    static func parseLyricsPlus(_ data: Data) -> MusicLyrics {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return MusicLyrics() }
        let nested = object["data"] as? [String: Any]
        let entries = object["lyrics"] as? [[String: Any]] ?? nested?["lyrics"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? []
        let timed = (object["type"] as? String ?? nested?["type"] as? String ?? "").uppercased() != "NONE"
        let lines = entries.compactMap { entry -> (Double?, String)? in
            let words = entry["syllabus"] as? [[String: Any]] ?? entry["words"] as? [[String: Any]] ?? []
            let text = (entry["text"] as? String ?? words.filter { ($0["isBackground"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let milliseconds = (entry["time"] as? NSNumber)?.doubleValue ?? (entry["time"] as? String).flatMap(Double.init)
            let time = timed ? milliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 / 1000 : nil } : nil
            return (time, text)
        }.sorted { ($0.0 ?? .infinity) < ($1.0 ?? .infinity) }
        return MusicLyrics(lines: lines.enumerated().map { MusicLyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) })
    }

    static func validURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    static func artwork(for media: MediaItem) async -> MusicArtworkResult {
        let title = cleaned(media.title), artist = cleaned(media.artist)
        guard !title.isEmpty, !artist.isEmpty else { return MusicArtworkResult(still: media.artworkUrl) }
        var requests: [URL] = []
        if let album = media.album, !album.isEmpty,
           let url = query("https://artwork.m8tec.top/api/v1/artwork/search", ["artist": artist, "album": cleaned(album), "title": title]) {
            requests.append(url)
        }
        if let url = query("https://artwork.boidu.dev/", ["s": title, "a": artist]) { requests.append(url) }
        for url in requests {
            guard !Task.isCancelled else { break }
            guard let data = try? await fetch(url), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let object = (json as? [[String: Any]])?.first ?? (json as? [String: Any])
            guard let object, object["error"] == nil else { continue }
            if let foundArtist = object["artist"] as? String, !foundArtist.isEmpty {
                let left = cleaned(foundArtist).lowercased(), right = artist.lowercased()
                guard left.contains(right) || right.contains(left) else { continue }
            }
            if let expectedAlbum = media.album, !expectedAlbum.isEmpty,
               let foundAlbum = object["album"] as? String, !foundAlbum.isEmpty,
               cleaned(expectedAlbum).localizedCaseInsensitiveCompare(cleaned(foundAlbum)) != .orderedSame { continue }
            let still = validURL(object["static"]) ?? media.artworkUrl
            let motion = validURL(object["videoUrl"]) ?? validURL(object["animated"]) ?? validURL(object["url"])
            if let motion { return MusicArtworkResult(still: still, motion: motion) }
        }
        return MusicArtworkResult(still: media.artworkUrl)
    }
}

