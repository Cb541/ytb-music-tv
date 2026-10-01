import Foundation

struct MusicLyricWord: Equatable {
    let text: String
    let start: Double
    let end: Double
}

struct MusicLyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double?
    let text: String
    var words: [MusicLyricWord] = []
}

struct MusicLyrics: Equatable {
    var lines: [MusicLyricLine] = []
    var instrumental = false
    var synchronized: Bool { lines.contains { $0.time != nil } }

    var wordSynchronized: Bool { lines.contains { !$0.words.isEmpty } }

    static func parse(synced: String?, plain: String?, instrumental: Bool) -> MusicLyrics {
        let pattern = #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var entries: [(Double, String)] = []
        var offset = 0.0
        for raw in (synced ?? "").components(separatedBy: .newlines) {
            if raw.hasPrefix("[offset:"), let end = raw.firstIndex(of: "]"),
               let milliseconds = Double(raw[raw.index(raw.startIndex, offsetBy: 8)..<end]) {
                offset = milliseconds / 1000
            }
            let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            guard let last = matches.last, let range = Range(last.range, in: raw) else { continue }
            let text = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: raw),
                      let secondsRange = Range(match.range(at: 2), in: raw),
                      let minutes = Double(raw[minutesRange]), let seconds = Double(raw[secondsRange]) else { continue }
                entries.append((minutes * 60 + seconds, text))
            }
        }
        if !entries.isEmpty {
            let lines = entries.sorted { $0.0 < $1.0 }.enumerated().map {
                MusicLyricLine(id: $0.offset, time: max(0, $0.element.0 + offset), text: $0.element.1)
            }
            return MusicLyrics(lines: lines, instrumental: instrumental)
        }
        let lines = (plain ?? "").components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .enumerated().map { MusicLyricLine(id: $0.offset, time: nil, text: $0.element) }
        return MusicLyrics(lines: lines, instrumental: instrumental)
    }

    func activeLine(at seconds: Double) -> Int? {
        lines.last { ($0.time ?? .infinity) <= seconds }?.id
    }
}

