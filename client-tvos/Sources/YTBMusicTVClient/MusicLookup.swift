import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MusicArtworkResult: Sendable {
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

struct MusicCatalogAlbum: Sendable {
    var name: String
    var id: String?
    var page: URL?
}

enum MusicLookup {
    static func cleaned(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)\s*\([^)]*(official|video|audio|lyrics?|visualizer|4k|hd)[^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*\[[^\]]*(official|video|audio|lyrics?|visualizer|4k|hd)[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*[-–—]\s*Topic$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetch(_ url: URL, timeout: TimeInterval = 9) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
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

    static func playerHeading(_ media: MediaItem) -> String {
        let artist = media.artist.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"(?i)\s*[-–—]\s*Topic$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: ", ")
        guard let album = media.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty else { return artist }
        // Some providers expose singles as albums named after the song.
        let isSingle = normalized(album) == "single" || album.range(of: #"(?i)(?:\s*[-–—]\s*|\s+|\s*\()(?:single)\)?$"#, options: .regularExpression) != nil
            || normalized(album) == normalized(songTitle(media.title, artist: artist))
        guard !isSingle else { return artist }
        return artist.isEmpty ? album : artist + " • " + album
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

    // Featuring credits vary across YouTube and Apple catalogs. Ignore only
    // those credits for cover matching; live/remix/version labels still matter.
    static func artworkTitle(_ value: String) -> String {
        cleaned(value)
            .replacingOccurrences(of: #"(?i)\s*[\(\[]\s*from\s+[^\)\]]+(?:album|soundtrack)[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]+[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+[^\(\[]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let title = cleaned(songTitle(media.title, artist: media.artist)), artist = cleaned(media.artist)
        guard !title.isEmpty, !artist.isEmpty else { return MusicLyrics() }
        var parameters = ["title": title, "artist": artist, "source": "apple,musixmatch,spotify,qq"]
        if let album = media.album, !album.isEmpty { parameters["album"] = cleaned(album) }
        if media.durationMs > 0 { parameters["duration"] = String(Double(media.durationMs) / 1000) }
        let requests = ["https://lyricsplus.binimum.org", "https://lyricsplus.prjktla.workers.dev", "https://lyricsplus-seven.vercel.app"].enumerated().compactMap { index, host -> (URL, Int, Bool)? in
            query(host + "/v2/lyrics/get", parameters).map { ($0, index * 1500, false) }
        }
        var extra = parameters
        extra.removeValue(forKey: "source")
        if let videoID = media.videoId { extra["v"] = videoID }
        let additional = query("https://api.liriqo-alfarrizi.my.id/v1/lyrics", extra)
        let sources = requests + (additional.map { [($0, 1200, true)] } ?? [])
        return await withTaskGroup(of: MusicLyrics.self) { group in
            for (url, delay, isLiriqo) in sources {
                group.addTask {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                    guard !Task.isCancelled, let data = try? await fetch(url, timeout: isLiriqo ? 22 : 9), !Task.isCancelled else { return MusicLyrics() }
                    return isLiriqo ? parseLiriqo(data, media: media) : parseLyricsPlus(data)
                }
            }
            var fallback = MusicLyrics()
            for await result in group {
                if result.wordSynchronized { group.cancelAll(); return result }
                if (result.synchronized && !fallback.synchronized) || (fallback.lines.isEmpty && !result.lines.isEmpty) { fallback = result }
            }
            return fallback
        }
    }

    static func parseLiriqo(_ data: Data, media: MediaItem) -> MusicLyrics {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return MusicLyrics() }
        let object = root["data"] as? [String: Any] ?? root
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        if let title = metadata["title"] as? String, !title.isEmpty,
           normalized(title) != normalized(cleaned(songTitle(media.title, artist: media.artist))) { return MusicLyrics() }
        if let artist = metadata["artist"] as? String, !artist.isEmpty,
           normalized(primaryArtist(artist)) != normalized(primaryArtist(media.artist)) { return MusicLyrics() }
        let metadataDuration = (metadata["duration"] as? NSNumber)?.doubleValue ?? (metadata["duration"] as? String).flatMap(Double.init)
        if let duration = metadataDuration, media.durationMs > 0,
           abs(duration - Double(media.durationMs) / 1000) > 12 { return MusicLyrics() }
        var tracks = object["tracks"] as? [[String: Any]] ?? []
        if let primary = object["primary"] as? [String: Any] { tracks.insert(primary, at: 0) }
        var ranked: [(MusicLyrics, Int)] = []
        for track in tracks {
            let provider = (track["provider"] as? String ?? "").lowercased()
            // The synthesized LRCLIB word track also splits real lines into
            // estimated single-word lines. Use its ordinary LRCLIB track instead.
            if provider.contains("lrclib") && provider.contains("wordsync") { continue }
            let rawLines = track["timed"] as? [[String: Any]] ?? []
            let largestTime = rawLines.compactMap { ($0["end"] as? NSNumber)?.doubleValue ?? ($0["start"] as? NSNumber)?.doubleValue }.max() ?? 0
            let duration = media.durationMs > 0 ? Double(media.durationMs) / 1000 : metadataDuration ?? 1200
            // The hosted API currently uses milliseconds, while its documented
            // seconds format is accepted too. Match the time scale to song length.
            let timeScale = largestTime <= duration + 30 ? 1000.0 : 1.0
            let allowWords = !provider.contains("lrclib") && ["word", "syllable"].contains(track["syncLevel"] as? String ?? "")
            func milliseconds(_ value: Any?) -> Double? {
                guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
                return number.doubleValue * timeScale
            }
            let entries = rawLines.map { line -> [String: Any] in
                var result: [String: Any] = ["text": line["text"] as? String ?? ""]
                result["time"] = milliseconds(line["start"])
                result["endTime"] = milliseconds(line["end"])
                if allowWords {
                    result["words"] = (line["words"] as? [[String: Any]] ?? []).compactMap { word -> [String: Any]? in
                        guard let start = milliseconds(word["start"]), let end = milliseconds(word["end"]), end >= start,
                              let text = word["text"] as? String else { return nil }
                        return ["text": text, "time": start, "duration": end - start]
                    }
                }
                return result
            }
            var lyrics = MusicLyrics()
            if let converted = try? JSONSerialization.data(withJSONObject: ["lyrics": entries, "type": "LINE"]) { lyrics = parseLyricsPlus(converted) }
            if lyrics.lines.isEmpty { lyrics = MusicLyrics.parse(synced: nil, plain: track["plain"] as? String, instrumental: false) }
            let rank = (lyrics.wordSynchronized ? 100 : lyrics.synchronized ? 50 : 0) + (provider.contains("apple") ? 10 : 0)
            if !lyrics.lines.isEmpty { ranked.append((lyrics, rank)) }
        }
        return ranked.sorted { $0.1 > $1.1 }.first?.0 ?? MusicLyrics()
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
            let foundAlbum = object["album"] as? String ?? object["collectionName"] as? String
            let albumNamedResponse = object["track"] == nil && object["trackName"] == nil &&
                album != nil && albumKey(foundTitle ?? "") == albumKey(album ?? "") &&
                (object["albumId"] != nil || object["collectionId"] != nil)
            if let foundTitle, !foundTitle.isEmpty, normalized(artworkTitle(foundTitle)) != normalized(artworkTitle(title)), !albumNamedResponse { continue }
            if foundTitle == nil && foundAlbum == nil { continue }
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

    static func catalogAlbums(_ data: Data, title: String, artist: String, album: String?, durationMs: Int) -> [MusicCatalogAlbum] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["results"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return records.compactMap { record in
            guard normalized(artworkTitle(record["trackName"] as? String ?? "")) == normalized(artworkTitle(title)),
                  normalized(primaryArtist(record["artistName"] as? String ?? "")) == normalized(primaryArtist(artist)),
                  durationMs <= 0 || record["trackTimeMillis"] == nil ||
                    abs((record["trackTimeMillis"] as? Int ?? durationMs) - durationMs) <= 12000,
                  album == nil || albumKey(record["collectionName"] as? String ?? "") == albumKey(album ?? "") ||
                    normalized(artworkTitle(album ?? "").replacingOccurrences(of: #"(?i)\s*[-–—]\s*Single$"#, with: "", options: .regularExpression)) == normalized(artworkTitle(title)),
                  let name = record["collectionName"] as? String, !name.isEmpty else { return nil }
            let id = (record["collectionId"] as? NSNumber)?.stringValue
            let page = validURL(record["collectionViewUrl"]).flatMap { $0.host == "music.apple.com" ? $0 : nil }
            guard seen.insert(id ?? page?.absoluteString ?? albumKey(name)).inserted else { return nil }
            return MusicCatalogAlbum(name: name, id: id, page: page)
        }
    }

    static func catalogAlbum(_ data: Data, title: String, artist: String, album: String?, durationMs: Int) -> MusicCatalogAlbum? {
        catalogAlbums(data, title: title, artist: artist, album: album, durationMs: durationMs).first
    }

    static func discoveredAlbum(_ data: Data, title: String, artist: String, durationMs: Int) -> String? {
        catalogAlbum(data, title: title, artist: artist, album: nil, durationMs: durationMs)?.name
    }

    // Only read motion belonging to this album. Recommended albums elsewhere on
    // the page must never supply the current song's artwork.
    static func applePageArtwork(_ data: Data, albumID: String, fallback: URL?) -> MusicArtworkResult? {
        guard let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"(?is)<script\b[^>]*\bid=["']serialized-server-data["'][^>]*>(.*?)</script>"#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let json = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)) else { return nil }
        func find(_ value: Any, depth: Int = 0) -> URL? {
            guard depth < 30 else { return nil }
            if let array = value as? [Any] {
                for element in array { if let url = find(element, depth: depth + 1) { return url } }
            } else if let object = value as? [String: Any] {
                let descriptor = object["contentDescriptor"] as? [String: Any]
                let identifiers = descriptor?["identifiers"] as? [String: Any]
                let id = identifiers?["storeAdamID"] as? String ?? object["id"] as? String ?? (object["id"] as? NSNumber)?.stringValue ?? object["adamId"] as? String
                if id == albumID && (descriptor == nil || descriptor?["kind"] as? String == "album") {
                    let attributes = object["attributes"] as? [String: Any] ?? object
                    let videoArtwork = object["videoArtwork"] as? [String: Any]
                    let editorial = attributes["editorialVideo"] as? [String: Any] ?? videoArtwork?["dictionary"] as? [String: Any] ?? [:]
                    for key in ["motionDetailSquare", "motionSquareVideo1x1"] {
                        if let video = editorial[key] as? [String: Any], let url = motionURL(video["video"]) { return url }
                    }
                    if let motion = attributes["motionArtwork"] as? [String: Any],
                       let url = motionURL(motion["videoUrl"] ?? motion["url"]) { return url }
                }
                for element in object.values { if let url = find(element, depth: depth + 1) { return url } }
            }
            return nil
        }
        guard let motion = find(json) else { return nil }
        return MusicArtworkResult(still: fallback, motion: motion)
    }

    static func catalogArtwork(_ catalog: MusicCatalogAlbum, country: String, title: String, artist: String, durationMs: Int, fallback: URL?) async -> MusicArtworkResult? {
        let page = catalog.page ?? catalog.id.flatMap { URL(string: "https://music.apple.com/" + country + "/album/" + $0) }
        var requests = artworkRequests(title: title, artist: artist, album: catalog.name, durationMs: durationMs, includeCatalog: false)
        if let page {
            requests = [
                query("https://artwork.m8tec.top/api/v1/artwork/url", ["url": page.absoluteString]),
                query("https://artwork.boidu.dev/", ["url": page.absoluteString]),
                query("https://apple-music-artwork.nopxx.site/api/search", ["term": page.absoluteString, "animation": "1"])
            ].compactMap { $0 }
        }
        let resolvedRequests = requests
        return await withTaskGroup(of: MusicArtworkResult?.self) { group in
            group.addTask { await firstArtwork(from: resolvedRequests, title: title, artist: artist, album: catalog.name, fallback: fallback) }
            if let page, let id = catalog.id {
                group.addTask {
                    guard !Task.isCancelled, let data = try? await fetch(page), !Task.isCancelled else { return nil }
                    return applePageArtwork(data, albumID: id, fallback: fallback)
                }
            }
            for await result in group { if let result { group.cancelAll(); return result } }
            return nil
        }
    }

    static func firstArtwork(
        from requests: [URL], title: String, artist: String, album: String?, fallback: URL?,
        load: @escaping @Sendable (URL) async throws -> Data = { try await fetch($0) }
    ) async -> MusicArtworkResult? {
        await withTaskGroup(of: MusicArtworkResult?.self) { group in
            for url in requests {
                group.addTask {
                    guard !Task.isCancelled, let data = try? await load(url), !Task.isCancelled else { return nil }
                    return artworkResult(data, title: title, artist: artist, album: album, fallback: fallback)
                }
            }
            for await result in group {
                if let result { group.cancelAll(); return result }
            }
            return nil
        }
    }

    static func artworkRequests(title: String, artist: String, album: String?, durationMs: Int, includeCatalog: Bool = true) -> [URL] {
        var requests: [URL] = []
        var boidu = ["s": title, "a": artist]
        if let album { boidu["al"] = album }
        if durationMs > 0 { boidu["d"] = String(durationMs / 1000) }
        if let album, let url = query("https://artwork.m8tec.top/api/v1/artwork/search", ["artist": artist, "album": album]) {
            requests.append(url)
        }
        if let url = query("https://artwork.boidu.dev/", boidu) { requests.append(url) }
        if includeCatalog, let url = query("https://apple-music-artwork.nopxx.site/api/search", ["term": artist + " " + title, "limit": "8", "animation": "1"]) {
            requests.append(url)
        }
        return requests
    }

    static func artwork(for media: MediaItem) async -> MusicArtworkResult {
        let title = artworkTitle(songTitle(media.title, artist: media.artist)), artist = primaryArtist(media.artist)
        guard !title.isEmpty, !artist.isEmpty else { return MusicArtworkResult(still: media.artworkUrl) }
        let album = media.album.map(cleaned).flatMap { $0.isEmpty ? nil : $0 }
        let durationMs = media.durationMs, fallback = media.artworkUrl
        let direct = artworkRequests(title: title, artist: artist, album: album, durationMs: durationMs)
        let result: MusicArtworkResult? = await withTaskGroup(of: MusicArtworkResult?.self) { group in
            group.addTask {
                await firstArtwork(from: direct, title: title, artist: artist, album: album, fallback: fallback)
            }
            for (index, country) in ["us", "gb"].enumerated() {
                group.addTask {
                    if index > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                    guard !Task.isCancelled,
                          let url = query("https://itunes.apple.com/search", ["term": artist + " " + title, "entity": "song", "country": country, "limit": "12"]),
                          let data = try? await fetch(url), !Task.isCancelled else { return nil }
                    // A single may appear on several legitimate catalog releases.
                    // Try more than the first hit, with a bound on network fan-out.
                    let catalogs = catalogAlbums(data, title: title, artist: artist, album: album, durationMs: durationMs)
                    return await withTaskGroup(of: MusicArtworkResult?.self) { matches in
                        for catalog in catalogs.prefix(3) {
                            matches.addTask {
                                guard !Task.isCancelled else { return nil }
                                return await catalogArtwork(catalog, country: country, title: title, artist: artist, durationMs: durationMs, fallback: fallback)
                            }
                        }
                        for await result in matches { if let result { matches.cancelAll(); return result } }
                        return nil
                    }
                }
            }
            for await result in group {
                if let result { group.cancelAll(); return result }
            }
            return nil
        }
        return result ?? MusicArtworkResult(still: media.artworkUrl)
    }
}
