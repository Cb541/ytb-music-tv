import Foundation

enum MusicTestInput: Equatable {
    case search(String)
    case songID(String)

    static func parse(_ raw: String) -> MusicTestInput? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.allSatisfy(\.isNumber) { return .songID(value) }
        if let url = URLComponents(string: value),
           url.scheme == "https", url.host?.lowercased() == "music.apple.com" {
            if let id = url.queryItems?.first(where: { $0.name == "i" })?.value,
               !id.isEmpty, id.allSatisfy(\.isNumber) {
                return .songID(id)
            }
            let components = url.path.split(separator: "/")
            if components.contains("song"), let id = components.last,
               !id.isEmpty, id.allSatisfy(\.isNumber) {
                return .songID(String(id))
            }
        }
        return .search(value)
    }
}

enum AtmosEvidence {
    static func label(isPlaying: Bool, activeVariant: String?) -> String {
        guard isPlaying else { return "Waiting for playback" }
        return activeVariant ?? "Not reported yet"
    }

    static func isConfirmed(isPlaying: Bool, activeVariant: String?) -> Bool {
        isPlaying && activeVariant == "Dolby Atmos"
    }
}
