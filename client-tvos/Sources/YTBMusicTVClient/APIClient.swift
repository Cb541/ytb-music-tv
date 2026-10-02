import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct APIClient {
    let baseURL: URL
    let accessToken: String?

    private let session: URLSession = .shared

    init(baseURL: URL, accessToken: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func health() async throws -> ServerConnectionInfo {
        try await get("/api/health")
    }

    func config() async throws -> ServerConfig {
        try await get("/api/config")
    }

    func patchConfig(_ config: ServerConfig) async throws -> ServerConfig {
        try await patch("/api/config", body: config)
    }

    func pair(deviceCode: String, name: String = "Apple TV") async throws -> PairingResult {
        try await post("/api/pair", body: PairingRequest(name: name, deviceCode: deviceCode))
    }

    func search(query: String, type: String? = "song") async throws -> MediaSectionResponse {
        var items = [URLQueryItem(name: "q", value: query)]
        if let type {
            items.append(URLQueryItem(name: "type", value: type))
        }
        return try await get("/api/search", queryItems: items)
    }

    func explore() async throws -> MediaSectionResponse {
        try await get("/api/explore")
    }

    func playlistSearch(media: MediaItem, query: String) async throws -> MediaSectionResponse {
        try await post("/api/playlist/search", body: PlaylistSearchRequest(media: media, query: query), timeout: 300)
    }

    func browseRelated(media: MediaItem, kind: String) async throws -> MediaSectionResponse {
        try await post("/api/browse/related", body: RelatedBrowseRequest(media: media, kind: kind))
    }

    func mix(mediaId: String) async throws -> MediaSectionResponse {
        try await get("/api/media/\(mediaId)/mix")
    }

    func home() async throws -> MediaSectionResponse {
        try await get("/api/home")
    }

    func library() async throws -> MediaSectionResponse {
        try await get("/api/library")
    }

    func browse(media: MediaItem) async throws -> MediaSectionResponse {
        try await post("/api/browse", body: BrowseRequest(media: media, paged: true, continuation: media.type == "playlist-page" ? media.tags.first : nil))
    }

    func setRating(mediaId: String, likeStatus: String) async throws -> RatingResult {
        try await put(
            "/api/media/\(mediaId)/rating",
            body: RatingRequest(likeStatus: likeStatus)
        )
    }

    func resolve(mediaId: String, preferVideo: Bool? = nil) async throws -> ResolvedStream {
        try await get(
            "/api/resolve/\(mediaId)",
            queryItems: preferVideo.map { [URLQueryItem(name: "preferVideo", value: String($0))] } ?? []
        )
    }

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        var request = request(path, queryItems: queryItems)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder.ytbMusicTV.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(path: path, detail: error.fieldDescription)
        }
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, timeout: TimeInterval = 60) async throws -> T {
        var request = request(path)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder.ytbMusicTV.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder.ytbMusicTV.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(path: path, detail: error.fieldDescription)
        }
    }

    private func patch<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = request(path)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder.ytbMusicTV.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder.ytbMusicTV.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(path: path, detail: error.fieldDescription)
        }
    }

    private func put<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = request(path)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder.ytbMusicTV.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder.ytbMusicTV.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(path: path, detail: error.fieldDescription)
        }
    }

    private func request(_ path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: url(path, queryItems: queryItems))
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    private func url(_ path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
            let message = payload?.message
                ?? payload?.error
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw APIError.http(status: http.statusCode, message: message)
        }
    }
}

private struct APIErrorPayload: Decodable {
    var error: String?
    var message: String?
}

private struct BrowseRequest: Encodable {
    var media: MediaItem
    var paged: Bool
    var continuation: String?
}

private struct PairingRequest: Encodable {
    var name: String
    var deviceCode: String
}

private struct RatingRequest: Encodable {
    var likeStatus: String
}

enum APIError: LocalizedError {
    case invalidResponse
    case decoding(path: String, detail: String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .decoding(path, detail):
            return "Server response \(path): \(detail)"
        case .invalidResponse:
            return "Invalid server response."
        case let .http(status, message):
            return "HTTP \(status): \(message)"
        }
    }
}

extension JSONDecoder {
    static var ytbMusicTV: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }
}

extension JSONEncoder {
    static var ytbMusicTV: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        return encoder
    }
}

private extension DecodingError {
    var fieldDescription: String {
        let context: Context
        switch self {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): context = c
        case .keyNotFound(let key, let c):
            return "Missing field " + (c.codingPath + [key]).map(\.stringValue).joined(separator: ".")
        @unknown default: return "Unable to decode playback response."
        }
        let field = context.codingPath.map(\.stringValue).joined(separator: ".")
        return (field.isEmpty ? "JSON" : field) + ": " + context.debugDescription
    }
}

private struct PlaylistSearchRequest: Encodable { var media: MediaItem; var query: String }
private struct RelatedBrowseRequest: Encodable { var media: MediaItem; var kind: String }
