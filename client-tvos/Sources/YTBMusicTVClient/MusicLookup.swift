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

    static func songTitle(_ value: String, artist: String) -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = title.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) else { return title }
        let prefix = normalized(String(title[..<separator.lowerBound]))
        guard !prefix.isEmpty, prefix == normalized(artist) || prefix == normalized(primaryArtist(artist)) else { return title }
        let remainder = String(title[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? title : remainder
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

    static func lrclibLyrics(for media: MediaItem) async -> MusicLyrics {
        let title = cleaned(songTitle(media.title, artist: media.artist)), artist = cleaned(media.artist)
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
        return fallback
    }

    static func lyrics(for media: MediaItem) async -> MusicLyrics {
        async let base = lrclibLyrics(for: media)
        async let rich = lyricsPlus(for: media)
        let (lineLyrics, wordLyrics) = await (base, rich)
        if wordLyrics.wordSynchronized { return wordLyrics }
        if lineLyrics.synchronized || lineLyrics.instrumental { return lineLyrics }
        return wordLyrics.lines.isEmpty ? lineLyrics : wordLyrics
    }

    static func lyricsPlus(for media: MediaItem) async -> MusicLyrics {
        var fallback = MusicLyrics()
        let title = cleaned(songTitle(media.title, artist: media.artist)), artist = cleaned(media.artist)
        guard !title.isEmpty, !artist.isEmpty else { return fallback }
        var parameters = ["title": title, "artist": artist]
        if let album = media.album, !album.isEmpty { parameters["album"] = cleaned(album) }
        if media.durationMs > 0 { parameters["duration"] = String(Double(media.durationMs) / 1000) }
        for host in ["https://lyricsplus.binimum.org", "https://lyricsplus.prjktla.workers.dev", "https://lyricsplus-seven.vercel.app"] {
            guard !Task.isCancelled else { return fallback }
            if let url = query(host + "/v2/lyrics/get", parameters), let data = try? await fetch(url) {
                let result = parseLyricsPlus(data)
                if result.wordSynchronized { return result }
                if !fallback.synchronized && result.synchronized { fallback = result }
            }
        }
        return fallback
    }

    static func parseLyricsPlus(_ data: Data) -> MusicLyrics {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return MusicLyrics() }
        let nested = object["data"] as? [String: Any]
        let entries = object["lyrics"] as? [[String: Any]] ?? nested?["lyrics"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? []
        let timed = (object["type"] as? String ?? nested?["type"] as? String ?? "").uppercased() != "NONE"
        func seconds(_ value: Any?) -> Double? {
            let value = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
            return value.flatMap { $0.isFinite && $0 >= 0 ? $0 / 1000 : nil }
        }
        let lines = entries.compactMap { entry -> MusicLyricLine? in
            let rawWords = entry["syllabus"] as? [[String: Any]] ?? entry["words"] as? [[String: Any]] ?? []
            let mainWords = rawWords.filter { ($0["isBackground"] as? Bool) != true }
            let text = (entry["text"] as? String ?? mainWords.compactMap { $0["text"] as? String }.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let time = timed ? seconds(entry["time"]) : nil
            let rawTimed = mainWords.compactMap { word -> (String, Double, Double?)? in
                guard timed, let text = word["text"] as? String, !text.isEmpty,
                      let start = seconds(word["time"]) else { return nil }
                return (text, start, seconds(word["duration"]))
            }.sorted { $0.1 < $1.1 }
            let lineEnd = seconds(entry["endTime"]) ?? time.flatMap { start in seconds(entry["duration"]).map { start + $0 } }
            var words = rawTimed.enumerated().map { index, word in
                let next = index + 1 < rawTimed.count ? rawTimed[index + 1].1 : lineEnd ?? word.1
                return MusicLyricWord(text: word.0, start: word.1, end: max(word.1, word.2.map { word.1 + $0 } ?? next))
            }
            // Only use word rendering if it reproduces the provider's line text.
            var reconstructed = words.map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let normalizedText = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if reconstructed != normalizedText,
               words.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ") == normalizedText {
                words = words.enumerated().map { index, word in
                    MusicLyricWord(text: word.text + (index == words.count - 1 ? "" : " "), start: word.start, end: word.end)
                }
                reconstructed = normalizedText
            }
            return MusicLyricLine(id: 0, time: time ?? words.first?.start, text: text,
                                  words: reconstructed == normalizedText ? words : [])
        }.sorted { ($0.time ?? .infinity) < ($1.time ?? .infinity) }
        return MusicLyrics(lines: lines.enumerated().map { MusicLyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text, words: $0.element.words) })
    }

    static func validURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    static func albumKey(_ value: String) -> String {
        let base = cleaned(value)
            .replacingOccurrences(of: #"(?i)\s*[\(\[][^\)\]]*(deluxe|expanded|remaster|anniversary|edition)[^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*-\s*(deluxe|expanded|remaster|anniversary).*"#, with: "", options: .regularExpression)
        return normalized(base)
    }

    static func motionURL(_ value: Any?) -> URL? {
        guard let url = validURL(value), ["m3u8", "mp4", "mov"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    static func artworkResult(_ data: Data, title: String, artist: String, album: String?, fallback: URL?) -> MusicArtworkResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let dictionary = json as? [String: Any]
        let objects = json as? [[String: Any]] ?? dictionary?["results"] as? [[String: Any]] ?? dictionary.map { [$0] } ?? []
        for object in objects {
            guard object["error"] == nil else { continue }
            let foundArtist = object["artist"] as? String ?? object["artistName"] as? String
            guard let foundArtist, normalized(primaryArtist(foundArtist)) == normalized(primaryArtist(artist)) else { continue }
            let foundTitle = object["track"] as? String ?? object["trackName"] as? String ?? object["name"] as? String
            if let foundTitle, !foundTitle.isEmpty, normalized(foundTitle) != normalized(title) { continue }
            let foundAlbum = object["album"] as? String ?? object["collectionName"] as? String
            if foundTitle == nil, let album, !album.isEmpty, let foundAlbum,
               albumKey(album) != albumKey(foundAlbum) { continue }
            let animation = object["animation"] as? [String: Any]
            let square = animation?["square"] as? [String: Any]
            let motion = motionURL(object["videoUrl"]) ?? motionURL(object["animated"]) ?? motionURL(object["url"])
                ?? motionURL(animation?["best"]) ?? motionURL(square?["1080p"]) ?? motionURL(square?["768p"])
            guard let motion else { continue }
            let still = validURL(object["static"]) ?? validURL(object["artworkHi"]) ?? validURL(object["artwork"]) ?? fallback
            return MusicArtworkResult(still: still, motion: motion)
        }
        return nil
    }

    static func discoveredAlbum(_ data: Data, title: String, artist: String, durationMs: Int) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["results"] as? [[String: Any]] else { return nil }
        return records.first { record in
            normalized(record["trackName"] as? String ?? "") == normalized(title) &&
            normalized(primaryArtist(record["artistName"] as? String ?? "")) == normalized(primaryArtist(artist)) &&
            (durationMs <= 0 || record["trackTimeMillis"] == nil ||
             abs((record["trackTimeMillis"] as? Int ?? durationMs) - durationMs) <= 12000)
        }?["collectionName"] as? String
    }

    static func artwork(for media: MediaItem) async -> MusicArtworkResult {
        let title = cleaned(songTitle(media.title, artist: media.artist)), artist = primaryArtist(media.artist)
        guard !title.isEmpty, !artist.isEmpty else { return MusicArtworkResult(still: media.artworkUrl) }
        var album = media.album.map(cleaned).flatMap { $0.isEmpty ? nil : $0 }
        if album == nil, let url = query("https://itunes.apple.com/search", ["term": artist + " " + title, "entity": "song", "country": "us", "limit": "12"]),
           let data = try? await fetch(url) {
            album = discoveredAlbum(data, title: title, artist: artist, durationMs: media.durationMs)
        }
        guard !Task.isCancelled else { return MusicArtworkResult(still: media.artworkUrl) }
        var requests: [URL] = []
        var boidu = ["s": title, "a": artist]
        if let album { boidu["al"] = album }
        if media.durationMs > 0 { boidu["d"] = String(media.durationMs / 1000) }
        if let album, let url = query("https://artwork.m8tec.top/api/v1/artwork/search", ["artist": artist, "album": album]) {
            requests.append(url)
        }
        if let url = query("https://artwork.boidu.dev/", boidu) { requests.append(url) }
        if let url = query("https://apple-music-artwork.nopxx.site/api/search", ["term": artist + " " + title, "limit": "8", "animation": "1"]) {
            requests.append(url)
        }
        for url in requests {
            guard !Task.isCancelled else { break }
            guard let data = try? await fetch(url) else { continue }
            if let result = artworkResult(data, title: title, artist: artist, album: album, fallback: media.artworkUrl) { return result }
        }
        return MusicArtworkResult(still: media.artworkUrl)
    }
}
