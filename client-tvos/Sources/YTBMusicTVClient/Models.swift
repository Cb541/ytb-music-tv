import Foundation

struct ServerConfig: Codable, Equatable {
    var features: FeatureConfig
    var playback: PlaybackConfig
}

struct FeatureConfig: Codable, Equatable {
    var adblock: ToggleFeature
    var skipDislikedSongs: ToggleFeature
}

struct ToggleFeature: Codable, Equatable {
    var enabled: Bool
}

struct PlaybackConfig: Codable, Equatable {
    var selectedLibrary: String?
    var preferVideo: Bool
    var defaultQuality: String?
    var streamMode: String?
}

struct PlayerState: Codable, Equatable {
    var status: String
    var currentTimeMs: Int
    var currentMediaId: String?
    var currentMedia: MediaItem?
    var queue: [MediaItem]
    var shuffle: Bool
    var repeatMode: String?
}

struct MediaItem: Codable, Identifiable, Equatable {
    var id: String
    var videoId: String?
    var browseId: String?
    var playlistId: String?
    var type: String?
    var title: String
    var artist: String
    var album: String?
    var artistBrowseId: String?
    var albumBrowseId: String?
    var durationMs: Int
    var artworkUrl: URL?
    var streamUrl: URL?
    var sourceUrl: URL?
    var playbackUrl: URL?
    var likeStatus: String
    var tags: [String]
}

extension MediaItem {
    func matchesSearch(_ query: String) -> Bool {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || [title, artist, album ?? ""].joined(separator: " ").range(of: key, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    var isPlayable: Bool {
        videoId != nil || streamUrl != nil
    }
}

struct MediaSectionResponse: Codable, Equatable {
    var title: String?
    var playbackQueue: [MediaItem]?
    var continuation: String?
    var authRequired: Bool?
    var reason: String?
    var message: String?
    var filters: [String]?
    var sortOptions: [String]?
    var topButtons: [ExploreButton]?
    var sections: [MediaSection]
}

struct MediaSection: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var items: [MediaItem]
}

struct ExploreButton: Codable, Identifiable, Equatable {
    var id: String { browseId ?? title }
    var title: String
    var browseId: String?
}

struct ServerConnectionInfo: Codable, Equatable {
    var ok: Bool
    var service: String
    var version: String
    var serverId: String
    var serverName: String
    var associated: Bool
    var client: PairedClient?
    var authenticated: Bool
}

struct PairingResult: Codable, Equatable {
    var token: String
    var client: PairedClient
}

struct PairedClient: Codable, Equatable {
    var id: String
    var name: String
    var createdAt: String?
}

struct ResolvedStream: Codable, Equatable {
    var videoId: String
    var directUrl: URL
    var mimeType: String?
    var hasAudio: Bool?
    var hasVideo: Bool?
    var quality: String?
    var audioBitrate: Int?
    var expiresAt: String?
    var proxyUrl: URL?
    var adaptiveVideoUrl: URL?
    var adaptiveAudioUrl: URL?
    var adaptiveVideoProxyUrl: URL?
    var adaptiveAudioProxyUrl: URL?
    var media: MediaItem?
}

struct RatingResult: Codable, Equatable {
    var videoId: String
    var likeStatus: String
}

// A malformed optional provider URL must not invalidate an otherwise playable song.
extension KeyedDecodingContainer {
    func tolerantURL(forKey key: Key) -> URL? {
        guard let text = try? decode(String.self, forKey: key),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    func tolerantInt(forKey key: Key, fallback: Int = 0) -> Int {
        if let number = try? decode(Int.self, forKey: key) { return number }
        if let text = try? decode(String.self, forKey: key), let number = Int(text) { return number }
        return fallback
    }
}

extension MediaItem {
    enum CodingKeys: String, CodingKey {
        case id, videoId, browseId, playlistId, type, title, artist, album, durationMs
        case artworkUrl, streamUrl, sourceUrl, playbackUrl, likeStatus, tags, artistBrowseId, albumBrowseId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        videoId = try? c.decode(String.self, forKey: .videoId)
        browseId = try? c.decode(String.self, forKey: .browseId)
        playlistId = try? c.decode(String.self, forKey: .playlistId)
        type = try? c.decode(String.self, forKey: .type)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
        album = try? c.decode(String.self, forKey: .album)
        artistBrowseId = try? c.decode(String.self, forKey: .artistBrowseId)
        albumBrowseId = try? c.decode(String.self, forKey: .albumBrowseId)
        durationMs = max(0, c.tolerantInt(forKey: .durationMs))
        artworkUrl = c.tolerantURL(forKey: .artworkUrl)
        streamUrl = c.tolerantURL(forKey: .streamUrl)
        sourceUrl = c.tolerantURL(forKey: .sourceUrl)
        playbackUrl = c.tolerantURL(forKey: .playbackUrl)
        likeStatus = (try? c.decode(String.self, forKey: .likeStatus)) ?? "INDIFFERENT"
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
    }
}

extension ResolvedStream {
    enum CodingKeys: String, CodingKey {
        case videoId, directUrl, mimeType, hasAudio, hasVideo, quality, audioBitrate, expiresAt, proxyUrl
        case adaptiveVideoUrl, adaptiveAudioUrl, adaptiveVideoProxyUrl, adaptiveAudioProxyUrl, media
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = (try? c.decode(String.self, forKey: .videoId)) ?? ""
        proxyUrl = c.tolerantURL(forKey: .proxyUrl)
        guard let playableURL = c.tolerantURL(forKey: .directUrl) ?? proxyUrl else {
            throw DecodingError.dataCorruptedError(forKey: .directUrl, in: c,
                debugDescription: "The server returned no usable HTTP playback URL (directUrl or proxyUrl).")
        }
        directUrl = playableURL
        mimeType = try? c.decode(String.self, forKey: .mimeType)
        hasAudio = try? c.decode(Bool.self, forKey: .hasAudio)
        hasVideo = try? c.decode(Bool.self, forKey: .hasVideo)
        quality = try? c.decode(String.self, forKey: .quality)
        let bitrate = c.tolerantInt(forKey: .audioBitrate)
        audioBitrate = bitrate > 0 ? bitrate : nil
        expiresAt = try? c.decode(String.self, forKey: .expiresAt)
        adaptiveVideoUrl = c.tolerantURL(forKey: .adaptiveVideoUrl)
        adaptiveAudioUrl = c.tolerantURL(forKey: .adaptiveAudioUrl)
        adaptiveVideoProxyUrl = c.tolerantURL(forKey: .adaptiveVideoProxyUrl)
        adaptiveAudioProxyUrl = c.tolerantURL(forKey: .adaptiveAudioProxyUrl)
        media = try? c.decode(MediaItem.self, forKey: .media)
    }
}

// Browsing categories filter the current page without replacing it with a global search.
func filteredBrowseSections(_ sections: [MediaSection], category: String, query: String) -> [MediaSection] {
    sections.compactMap { section in
        let items = section.items.filter { media in
            let matchesCategory = category == "all" || media.type == category || (category == "song" && media.isPlayable)
            return matchesCategory && media.matchesSearch(query)
        }
        return items.isEmpty ? nil : MediaSection(id: section.id, title: section.title, items: items)
    }
}

struct PlaybackTiming: Equatable {
    var durationMs: Int
    var endTimeMs: Int?

    static func resolve(metadataMs: Int, streamSeconds: Double, hasVideo: Bool) -> PlaybackTiming {
        let metadata = max(0, metadataMs)
        let milliseconds = streamSeconds * 1000
        let stream = milliseconds.isFinite && milliseconds > 0 && milliseconds < Double(Int.max)
            ? Int(milliseconds) : 0
        guard metadata > 0 else { return PlaybackTiming(durationMs: stream, endTimeMs: nil) }
        // Some AAC streams expose an inflated container timeline with a silent
        // tail. Use the song metadata only for a clearly oversized audio timeline.
        // Small encoder differences and the actual length of videos remain intact.
        let inflatedAudio = !hasVideo && stream > metadata &&
            Double(stream - metadata) >= max(10_000, Double(metadata) * 0.5)
        if inflatedAudio || (!hasVideo && stream == 0) {
            return PlaybackTiming(durationMs: metadata, endTimeMs: metadata)
        }
        return PlaybackTiming(durationMs: stream > 0 ? stream : metadata, endTimeMs: nil)
    }
}
