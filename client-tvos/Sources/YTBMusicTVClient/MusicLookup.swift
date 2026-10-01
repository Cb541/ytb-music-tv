import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MusicArtworkResult {
    var still: URL?
    var motion: URL?
}

private struct LRCLIBRecord: Decodable {
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

    static func lyrics(for media: MediaItem) async -> MusicLyrics {
        let title = cleaned(media.title), artist = cleaned(media.artist)
        guard !title.isEmpty, !artist.isEmpty else { return MusicLyrics() }
        var exact = ["track_name": title, "artist_name": artist]
        if let album = media.album, !album.isEmpty { exact["album_name"] = cleaned(album) }
        if media.durationMs > 0 { exact["duration"] = String(Double(media.durationMs) / 1000) }
        if let url = query("https://lrclib.net/api/get", exact),
           let data = try? await fetch(url), let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) {
            return MusicLyrics.parse(synced: record.syncedLyrics, plain: record.plainLyrics, instrumental: record.instrumental == true)
        }
        guard !Task.isCancelled,
              let url = query("https://lrclib.net/api/search", ["track_name": title, "artist_name": artist]),
              let data = try? await fetch(url), let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data) else {
            return MusicLyrics()
        }
        let duration = Double(media.durationMs) / 1000
        // Do not synchronize a live/remix recording against a substantially different version.
        let compatible = records.filter { record in
            cleaned(record.trackName ?? "").localizedCaseInsensitiveCompare(title) == .orderedSame &&
            cleaned(record.artistName ?? "").localizedCaseInsensitiveCompare(artist) == .orderedSame &&
            (duration <= 0 || record.duration == nil || abs((record.duration ?? duration) - duration) < 5)
        }
        let sorted = compatible.sorted {
            if ($0.syncedLyrics != nil) != ($1.syncedLyrics != nil) { return $0.syncedLyrics != nil }
            return abs(($0.duration ?? duration) - duration) < abs(($1.duration ?? duration) - duration)
        }
        guard let record = sorted.first else { return MusicLyrics() }
        return MusicLyrics.parse(synced: record.syncedLyrics, plain: record.plainLyrics, instrumental: record.instrumental == true)
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

