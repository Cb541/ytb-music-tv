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
    var durationMs: Int
    var artworkUrl: URL?
    var streamUrl: URL?
    var sourceUrl: URL?
    var playbackUrl: URL?
    var likeStatus: String
    var tags: [String]
}

extension MediaItem {
    var isPlayable: Bool {
        videoId != nil || streamUrl != nil
    }
}

struct MediaSectionResponse: Codable, Equatable {
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
