import Foundation

@main
enum PlaybackAndLyricsTests {
    static func main() async throws {
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
        let legacyBrowse = try JSONDecoder().decode(MediaSectionResponse.self, from: Data(#"{"sections":[]}"#.utf8))
        precondition(legacyBrowse.continuation == nil)
        let pagedBrowse = try JSONDecoder().decode(MediaSectionResponse.self, from: Data(#"{"sections":[],"continuation":"next-page"}"#.utf8))
        precondition(pagedBrowse.continuation == "next-page")
        let pagedRoundTrip = try JSONDecoder().decode(MediaSectionResponse.self, from: JSONEncoder().encode(pagedBrowse))
        precondition(pagedRoundTrip == pagedBrowse)
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
        let candidates = try JSONDecoder().decode([LRCLIBRecord].self, from: Data(#"[{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"Plain"},{"trackName":"Song","artistName":"Artist","duration":188,"syncedLyrics":"[00:01.00]Timed"},{"trackName":"Song (Live)","artistName":"Artist","duration":180,"syncedLyrics":"[00:00.00]Wrong version"}]"#.utf8))
        let best = MusicLookup.bestLyrics(candidates, title: "Song", artist: "Artist", duration: 180)
        precondition(best.synchronized && best.lines.first?.text == "Timed")
        precondition(MusicLookup.bestLyrics(candidates, title: "Song", artist: "Someone else", duration: 180).lines.isEmpty)
        precondition(MusicLookup.bestLyrics([candidates[1]], title: "Song", artist: "Artist", duration: 220).lines.isEmpty)
        precondition(MusicLookup.primaryArtist("Artist feat. Guest") == "Artist")
        precondition(MusicLookup.normalized("Beyoncé") == MusicLookup.normalized("Beyonce"))
        let plus = MusicLookup.parseLyricsPlus(Data(#"{"type":"WORD","lyrics":[{"time":12000,"syllabus":[{"text":"Hello "},{"text":"world"},{"text":"Background","isBackground":true}]},{"time":1500,"text":"First"}]}"#.utf8))
        precondition(plus.synchronized && plus.lines.first?.time == 1.5)
        precondition(plus.lines.last?.text == "Hello world" && plus.activeLine(at: 12) == 1)
        let untimedPlus = MusicLookup.parseLyricsPlus(Data(#"{"type":"NONE","lyrics":[{"time":0,"text":"Plain"}]}"#.utf8))
        precondition(!untimedPlus.synchronized)
        precondition(MusicLookup.parseLyricsPlus(Data(#"{"lyrics":[{"text":"No timestamp"}]}"#.utf8)).synchronized == false)
        precondition(MusicLookup.albumKey("Album (Deluxe Edition)") == MusicLookup.albumKey("Album"))
        precondition(MusicLookup.albumKey("Album (Live)") != MusicLookup.albumKey("Album"))
        let m8tec = Data(#"{"artist":"Artist","album":"Album (Deluxe Edition)","url":"https://mvod.itunes.apple.com/motion.m3u8"}"#.utf8)
        precondition(MusicLookup.artworkResult(m8tec, title: "Song", artist: "Artist", album: "Album", fallback: nil)?.motion != nil)
        precondition(MusicLookup.artworkResult(m8tec, title: "Song", artist: "Other Artist", album: "Album", fallback: nil) == nil)
        precondition(MusicLookup.artworkResult(m8tec, title: "Song", artist: "Artist", album: "Different album", fallback: nil) == nil)
        let catalogMotion = Data(#"{"results":[{"track":"Different Song","artist":"Artist","animation":{"best":"https://mvod.itunes.apple.com/wrong.mp4"}},{"track":"Song","artist":"Artist & Guest","album":"Album","animation":{"best":"https://mvod.itunes.apple.com/right.mp4"},"artworkHi":"https://example.com/cover.jpg"}]}"#.utf8)
        let cover = MusicLookup.artworkResult(catalogMotion, title: "Song", artist: "Artist", album: "Album", fallback: nil)
        precondition(cover?.motion?.lastPathComponent == "right.mp4" && cover?.still != nil)
        precondition(MusicLookup.motionURL("https://music.apple.com/us/album/title/123") == nil)
        precondition(MusicLookup.motionURL("https://example.com/static.jpg") == nil)
        let catalog = Data(#"{"results":[{"trackName":"Other","artistName":"Artist","collectionName":"Wrong"},{"trackName":"Song","artistName":"Artist","collectionName":"Recovered Album","trackTimeMillis":180000}]}"#.utf8)
        precondition(MusicLookup.discoveredAlbum(catalog, title: "Song", artist: "Artist", durationMs: 181000) == "Recovered Album")
        precondition(MusicLookup.discoveredAlbum(catalog, title: "Song", artist: "Artist", durationMs: 220000) == nil)
        let wordTimed = MusicLookup.parseLyricsPlus(Data(#"{"type":"WORD","lyrics":[{"time":1000,"duration":3000,"text":"Hello world","syllabus":[{"text":"Hello ","time":1000,"duration":900},{"text":"world","time":2100,"duration":1200},{"text":"Adlib","time":1500,"duration":500,"isBackground":true}]}]}"#.utf8))
        precondition(wordTimed.wordSynchronized)
        precondition(wordTimed.lines[0].words.count == 2)
        precondition(wordTimed.lines[0].words[0].start == 1 && wordTimed.lines[0].words[0].end == 1.9)
        precondition(abs(wordTimed.lines[0].words[1].end - 3.3) < 0.0001)
        precondition(wordTimed.activeLine(at: 0.9) == nil && wordTimed.activeLine(at: 2.2) == 0)
        let spacedWords = MusicLookup.parseLyricsPlus(Data(#"{"type":"WORD","lyrics":[{"time":"0","duration":3000,"text":"One two","words":[{"text":"One","time":"0"},{"text":"two","time":1000}]}]}"#.utf8))
        precondition(spacedWords.wordSynchronized && spacedWords.lines[0].words.map(\.text).joined() == "One two")
        precondition(spacedWords.lines[0].words[0].end == 1 && spacedWords.lines[0].words[1].end == 3)
        let badWords = MusicLookup.parseLyricsPlus(Data(#"{"type":"WORD","lyrics":[{"time":1000,"text":"Actual lyric","words":[{"text":"Wrong lyric","time":1000}]}]}"#.utf8))
        precondition(badWords.synchronized && !badWords.wordSynchronized && badWords.lines[0].text == "Actual lyric")
        precondition(!untimedPlus.wordSynchronized && !timed.wordSynchronized)
        precondition(MusicLookup.songTitle("Pink Floyd - Comfortably Numb", artist: "Pink Floyd") == "Comfortably Numb")
        precondition(MusicLookup.songTitle("pink floyd – Comfortably Numb", artist: "Pink Floyd - Topic") == "Comfortably Numb")
        precondition(MusicLookup.songTitle("Song - Part Two", artist: "Pink Floyd") == "Song - Part Two")
        precondition(MusicLookup.songTitle("Pink Floyd - ", artist: "Pink Floyd") == "Pink Floyd -")
        let smoothWord = MusicLyricWord(text: "word", start: 1, end: 2)
        precondition(smoothWord.highlightProgress(at: 0.9) == 0)
        precondition(smoothWord.highlightProgress(at: 1) == 0)
        precondition(abs(smoothWord.highlightProgress(at: 1.15) - 0.5) < 0.0001)
        precondition(smoothWord.highlightProgress(at: 1.3) == 1)
        let quickWord = MusicLyricWord(text: "a", start: 0, end: 0.05)
        precondition(abs(quickWord.highlightProgress(at: 0.06) - 0.5) < 0.0001)
        precondition(smoothWord.highlightProgress(at: .nan) == 0)
        let probe = ArtworkRaceProbe()
        let fastProvider = URL(string: "https://example.com/fast-artwork")!
        let slowProvider = URL(string: "https://example.com/slow-artwork")!
        let racedArtwork = await MusicLookup.firstArtwork(from: [slowProvider, fastProvider], title: "Song", artist: "Artist", album: "Album", fallback: nil) { url in
            if url == slowProvider {
                await probe.started()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { await probe.cancelled(); throw error }
                return Data()
            }
            while !(await probe.hasStarted) { try await Task.sleep(nanoseconds: 1_000_000) }
            return m8tec
        }
        precondition(racedArtwork?.motion?.lastPathComponent == "motion.m3u8")
        let cancelledSlowProvider = await probe.wasCancelled
        precondition(cancelledSlowProvider)
        let noArtwork = await MusicLookup.firstArtwork(from: [fastProvider], title: "Song", artist: "Other Artist", album: "Album", fallback: nil) { _ in m8tec }
        precondition(noArtwork == nil)
        let searchable = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"id":"match","title":"Café Song","artist":"Artist","album":"Album"}"#.utf8))
        precondition(searchable.matchesSearch("CAFE") && searchable.matchesSearch("artist") && searchable.matchesSearch("album"))
        precondition(searchable.matchesSearch(" ") && !searchable.matchesSearch("missing"))
        let found = try JSONDecoder().decode(MediaSectionResponse.self, from: Data(#"{"sections":[],"playbackQueue":[{"id":"match","title":"Song"}],"title":"Artist"}"#.utf8))
        precondition(found.playbackQueue?.first?.id == "match" && found.title == "Artist")
        var headingMedia = searchable
        headingMedia.artist = "Pink Floyd - Topic  "
        headingMedia.title = "Pink Floyd - Comfortably Numb"
        headingMedia.album = "The Wall"
        precondition(MusicLookup.playerHeading(headingMedia) == "Pink Floyd • The Wall")
        headingMedia.album = nil
        precondition(MusicLookup.playerHeading(headingMedia) == "Pink Floyd")
        for single in ["Comfortably Numb", "Another Track - Single", "Another Track (Single)", "Single"] {
            headingMedia.album = single
            precondition(MusicLookup.playerHeading(headingMedia) == "Pink Floyd")
        }
        headingMedia.artist = "Artist – Topic, Guest - Topic"
        headingMedia.album = "Album"
        precondition(MusicLookup.playerHeading(headingMedia) == "Artist, Guest • Album")
        print("Playback decoding, lyric timing, and lookup metadata tests passed")
    }
}

private actor ArtworkRaceProbe {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false
    func started() { hasStarted = true }
    func cancelled() { wasCancelled = true }
}
