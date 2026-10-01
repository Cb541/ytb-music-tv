import Foundation

@main
enum PlaybackAndLyricsTests {
    static func main() throws {
        let response = #"{"videoId":"song","directUrl":{"unexpected":"object"},"proxyUrl":"http://192.168.1.10:4174/api/stream/song?preferVideo=false","adaptiveVideoUrl":{},"adaptiveAudioUrl":[],"adaptiveVideoProxyUrl":42,"adaptiveAudioProxyUrl":"","expiresAt":1234,"media":{"id":"song","title":"Test song","artist":"Artist","durationMs":"120000","artworkUrl":{},"sourceUrl":[]}}"#
        let stream = try JSONDecoder().decode(ResolvedStream.self, from: Data(response.utf8))
        precondition(stream.directUrl == stream.proxyUrl)
        precondition(stream.directUrl.query == "preferVideo=false")
        precondition(stream.adaptiveVideoUrl == nil && stream.adaptiveAudioUrl == nil)
        precondition(stream.adaptiveVideoProxyUrl == nil && stream.adaptiveAudioProxyUrl == nil)
        precondition(stream.media?.durationMs == 120000)
        precondition(stream.media?.artworkUrl == nil)
        precondition(stream.media?.likeStatus == "INDIFFERENT")
        precondition(stream.media?.tags == [])
        let encoded = try JSONEncoder().encode(stream)
        let roundTrip = try JSONDecoder().decode(ResolvedStream.self, from: encoded)
        precondition(roundTrip == stream)
        let progressive = #"{"videoId":"song","directUrl":"https://example.com/audio.m4a","proxyUrl":null,"hasAudio":true,"hasVideo":false}"#
        let audio = try JSONDecoder().decode(ResolvedStream.self, from: Data(progressive.utf8))
        precondition(audio.hasVideo == false && audio.hasAudio == true)
        precondition(audio.directUrl.host == "example.com")
        let malformedMedia = #"{"videoId":"song","directUrl":"https://example.com/video.mp4","media":{"bad":"metadata"}}"#
        let withoutMetadata = try JSONDecoder().decode(ResolvedStream.self, from: Data(malformedMedia.utf8))
        precondition(withoutMetadata.media == nil)
        do {
            _ = try JSONDecoder().decode(ResolvedStream.self, from: Data(#"{"videoId":"song","directUrl":"","proxyUrl":{}}"#.utf8))
            preconditionFailure("A response without any usable playback URL must fail")
        } catch DecodingError.dataCorrupted(let context) {
            precondition(context.codingPath.last?.stringValue == "directUrl")
        }
        let lrc = "[offset:200]\n[00:05.50]Five seconds\n[00:01.25][00:03.250]Repeated line\n[00:07.00]"
        let timed = MusicLyrics.parse(synced: lrc, plain: nil, instrumental: false)
        precondition(timed.synchronized && timed.lines.count == 4)
        precondition(abs((timed.lines[0].time ?? 0) - 1.45) < 0.0001)
        precondition(timed.activeLine(at: 1) == nil)
        precondition(timed.activeLine(at: 1.45) == 0)
        precondition(timed.activeLine(at: 3.6) == 1)
        precondition(timed.activeLine(at: 6) == 2)
        precondition(timed.activeLine(at: 9) == 3)
        precondition(timed.lines.last?.text == "")
        let plain = MusicLyrics.parse(synced: "[ar:Artist]", plain: "First line\n\nSecond line", instrumental: false)
        precondition(!plain.synchronized && plain.lines.count == 2)
        precondition(plain.activeLine(at: 100) == nil)
        precondition(MusicLyrics.parse(synced: nil, plain: nil, instrumental: true).instrumental)
        precondition(MusicLookup.cleaned("Yellow (Official Music Video)") == "Yellow")
        precondition(MusicLookup.cleaned("Coldplay - Topic") == "Coldplay")
        let query = MusicLookup.query("https://example.com/lyrics", ["artist_name": "A & B", "track_name": "Title / name"])
        let parameters = URLComponents(url: query!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(parameters.first { $0.name == "artist_name" }?.value == "A & B")
        precondition(parameters.first { $0.name == "track_name" }?.value == "Title / name")
        precondition(MusicLookup.validURL("https://example.com/art.m3u8") != nil)
        precondition(MusicLookup.validURL(["unexpected": "object"]) == nil)
        precondition(MusicLookup.validURL("file:///etc/passwd") == nil)
        print("Playback decoding, lyric timing, and lookup metadata tests passed")
    }
}
