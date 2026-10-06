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
        let tinyCover = URL(string: "https://lh3.googleusercontent.com/cover=w60-h60-l90-rj")!
        precondition(MusicLookup.highResolutionStillURL(tinyCover).absoluteString.hasSuffix("=w1200-h1200-l90-rj"))
        let appleCover = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music/cover/100x100bb.jpg")!
        precondition(MusicLookup.highResolutionStillURL(appleCover).path.hasSuffix("1200x1200bb.jpg"))
        let otherCover = URL(string: "https://example.com/100x100.jpg")!
        precondition(MusicLookup.highResolutionStillURL(otherCover) == otherCover)
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
        // YouTube omits or spells out credits that Apple puts in parentheses.
        let rockstarMotion = Data(#"{"name":"rockstar (feat. 21 Savage)","artist":"Post Malone","albumId":1373504837,"videoUrl":"https://mvod.itunes.apple.com/rockstar.mp4"}"#.utf8)
        for title in ["Rockstar", "rockstar ft. 21 Savage", "rockstar (featuring 21 Savage)", "rockstar [feat. 21 Savage]"] {
            precondition(MusicLookup.artworkResult(rockstarMotion, title: title, artist: "Post Malone – Topic", album: nil, fallback: nil)?.motion != nil)
        }
        for title in ["Rockstar (Live)", "Rockstar (Remix)", "Rockstar - Acoustic", "Different song"] {
            precondition(MusicLookup.artworkResult(rockstarMotion, title: title, artist: "Post Malone", album: nil, fallback: nil) == nil)
        }
        precondition(MusicLookup.artworkResult(rockstarMotion, title: "Rockstar", artist: "Other Artist", album: nil, fallback: nil) == nil)
        let appleMotion = Data(#"{"data":[{"id":"42","type":"albums","attributes":{"editorialVideo":{"motionSquareVideo1x1":{"video":"https://mvod.itunes.apple.com/square.m3u8"},"motionDetailTall":{"video":"https://mvod.itunes.apple.com/tall.m3u8"}}}}]}"#.utf8)
        precondition(MusicLookup.appleCatalogArtwork(appleMotion, albumID: "42", fallback: nil)?.motion?.lastPathComponent == "square.m3u8")
        precondition(MusicLookup.appleCatalogArtwork(appleMotion, albumID: "43", fallback: nil) == nil)
        let tallOnly = Data(#"{"data":[{"id":"42","type":"albums","attributes":{"editorialVideo":{"motionDetailTall":{"video":"https://mvod.itunes.apple.com/tall.m3u8"}}}}]}"#.utf8)
        precondition(MusicLookup.appleCatalogArtwork(tallOnly, albumID: "42", fallback: nil) == nil)
        let providerOrder = MusicLookup.artworkRequests(title: "Song", artist: "Artist", album: "Album", durationMs: 180000)
            .sorted { MusicLookup.artworkProviderRank($0) < MusicLookup.artworkProviderRank($1) }.map(\.host)
        precondition(providerOrder == ["artwork.boidu.dev", "apple-music-artwork.nopxx.site", "artwork.m8tec.top"])
        let multipleReleases = Data(#"{"results":[{"trackName":"rockstar (feat. 21 Savage)","artistName":"Post Malone","collectionName":"beerbongs & bentleys","collectionId":1,"trackTimeMillis":218146},{"trackName":"rockstar","artistName":"Post Malone","collectionName":"beerbongs & bentleys","collectionId":1,"trackTimeMillis":218146},{"trackName":"rockstar","artistName":"Post Malone","collectionName":"The Diamond Collection","collectionId":2,"trackTimeMillis":218146},{"trackName":"rockstar (Live)","artistName":"Post Malone","collectionName":"Live","collectionId":3,"trackTimeMillis":218146},{"trackName":"rockstar","artistName":"Other Artist","collectionName":"Other","collectionId":4,"trackTimeMillis":218146},{"trackName":"rockstar","artistName":"Post Malone","collectionName":"Wrong recording length","collectionId":5,"trackTimeMillis":418146}]}"#.utf8)
        precondition(MusicLookup.artworkTitle("Last Thing You Need (from GTAVI: The Album)") == "Last Thing You Need")
        precondition(MusicLookup.artworkTitle("Song (Live)") == "Song (Live)")
        let soundtrack = Data(#"{"results":[{"trackName":"Last Thing You Need","artistName":"Morgan Wallen","collectionName":"Grand Theft Auto VI: The Album","collectionId":6812476961,"trackTimeMillis":196000}]}"#.utf8)
        precondition(MusicLookup.catalogAlbums(soundtrack, title: "Last Thing You Need (from GTAVI: The Album)", artist: "Morgan Wallen, Grand Theft Auto VI", album: "Last Thing You Need (from GTAVI: The Album) - Single", durationMs: 196000).count == 1)
        let releases = MusicLookup.catalogAlbums(multipleReleases, title: "Rockstar ft. 21 Savage", artist: "Post Malone", album: nil, durationMs: 218000)
        precondition(releases.map(\.id) == ["1", "2"])
        precondition(MusicLookup.catalogAlbums(multipleReleases, title: "Rockstar", artist: "Post Malone", album: "beerbongs & bentleys", durationMs: 218000).map(\.id) == ["1"])
        precondition(MusicLookup.catalogAlbums(multipleReleases, title: "Rockstar", artist: "Post Malone", album: "Unknown album", durationMs: 218000).isEmpty)
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
        let providerFallback = await MusicLookup.firstArtwork(from: [slowProvider, fastProvider], title: "Rockstar", artist: "Post Malone", album: nil, fallback: nil) { url in
            if url == fastProvider { throw URLError(.badServerResponse) }
            try await Task.sleep(nanoseconds: 20_000_000)
            return rockstarMotion
        }
        precondition(providerFallback?.motion?.lastPathComponent == "rockstar.mp4")
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
        let qualityReport = try JSONDecoder().decode(ResolvedStream.self, from: Data(#"{"directUrl":"https://example.com/audio.m4a","audioBitrate":256000}"#.utf8))
        precondition(qualityReport.audioBitrate == 256000)
        for report in [#"{"directUrl":"https://example.com/audio.m4a","audioBitrate":null}"#, #"{"directUrl":"https://example.com/audio.m4a"}"#] {
            let unknownQuality = try JSONDecoder().decode(ResolvedStream.self, from: Data(report.utf8))
            precondition(unknownQuality.audioBitrate == nil)
        }
        let linked = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"id":"linked","videoId":"abcdefghijk","type":"song","title":"Song","artist":"Artist","durationMs":180000,"artistBrowseId":"UCartist","albumBrowseId":"MPRalbum"}"#.utf8))
        precondition(linked.artistBrowseId == "UCartist" && linked.albumBrowseId == "MPRalbum")
        let encodedLinked = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(linked))
        precondition(encodedLinked == linked)
        let albumItem = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"id":"MPRalbum","type":"album","title":"Album","artist":"Artist","artworkUrl":"https://example.com/cover.jpg"}"#.utf8))
        let browse = [MediaSection(id: "songs", title: "Songs", items: [linked]), MediaSection(id: "albums", title: "Albums", items: [albumItem])]
        precondition(filteredBrowseSections(browse, category: "all", query: "").count == 2)
        precondition(filteredBrowseSections(browse, category: "song", query: "").first?.items == [linked])
        precondition(filteredBrowseSections(browse, category: "album", query: "ARTIST").first?.items.first?.artworkUrl == albumItem.artworkUrl)
        precondition(filteredBrowseSections(browse, category: "playlist", query: "").isEmpty && browse.count == 2)
        let multiLyrics = Data(#"{"data":{"metadata":{"title":"Song","artist":"Artist","duration":180},"tracks":[{"provider":"lrclib_wordsync","syncLevel":"word","timed":[{"text":"Hello world","start":2,"end":4,"words":[{"text":"Hello ","start":2,"end":3},{"text":"world","start":3,"end":4}]}]},{"provider":"qq_portato","syncLevel":"word","timed":[{"text":"Hello world","start":2.5,"end":4.5,"words":[{"text":"Hello ","start":2.5,"end":3.5},{"text":"world","start":3.5,"end":4.5}]}]},{"provider":"golyrics_apple_music","syncLevel":"syllable","timed":[{"text":"Hello world","start":3,"end":5,"words":[{"text":"Hello ","start":3,"end":4},{"text":"world","start":4,"end":5}]}]}]}}"#.utf8)
        let richLyrics = MusicLookup.parseLiriqo(multiLyrics, media: linked)
        precondition(richLyrics.wordSynchronized && richLyrics.lines.first?.time == 3)
        precondition(richLyrics.lines.first?.words.last?.start == 4)
        var otherVersion = linked; otherVersion.title = "Song (Live)"
        precondition(MusicLookup.parseLiriqo(multiLyrics, media: otherVersion).lines.isEmpty)
        otherVersion = linked; otherVersion.durationMs = 240000
        precondition(MusicLookup.parseLiriqo(multiLyrics, media: otherVersion).lines.isEmpty)
        let estimated = Data(#"{"tracks":[{"provider":"lrclib_wordsync","syncLevel":"word","timed":[{"text":"Hello world","start":2,"end":4,"words":[{"text":"Hello ","start":2,"end":3},{"text":"world","start":3,"end":4}]}]}]}"#.utf8)
        let lineOnly = MusicLookup.parseLiriqo(estimated, media: linked)
        precondition(lineOnly.lines.isEmpty && !lineOnly.wordSynchronized)
        let plainFallback = MusicLookup.parseLiriqo(Data(#"{"tracks":[{"provider":"ytm_line","syncLevel":"plain","plain":"Hello world"}]}"#.utf8), media: linked)
        precondition(!plainFallback.synchronized && plainFallback.lines.first?.text == "Hello world")
        let millisecondLyrics = Data(#"{"metadata":{"title":"Song","artist":"Artist","duration":"180"},"tracks":[{"provider":"golyrics_apple_music","syncLevel":"syllable","timed":[{"text":"Hello world","start":33000,"end":35000,"words":[{"text":"Hello ","start":33000,"end":34000},{"text":"world","start":34000,"end":35000}]}]}]}"#.utf8)
        let millisecondsParsed = MusicLookup.parseLiriqo(millisecondLyrics, media: linked)
        precondition(millisecondsParsed.wordSynchronized && millisecondsParsed.lines.first?.time == 33)
        precondition(millisecondsParsed.lines.first?.words.last?.end == 35)
        let realLRC = Data(#"{"tracks":[{"provider":"lrclib","syncLevel":"line","timed":[{"text":"Hello world","start":2,"end":4,"words":[{"text":"Hello ","start":2,"end":3},{"text":"world","start":3,"end":4}]}]}]}"#.utf8)
        let lrclibLines = MusicLookup.parseLiriqo(realLRC, media: linked)
        precondition(lrclibLines.synchronized && !lrclibLines.wordSynchronized)
        let exactCatalog = Data(#"{"results":[{"trackName":"Song","artistName":"Artist","collectionName":"Album","collectionId":123,"collectionViewUrl":"https://music.apple.com/us/album/album/123","trackTimeMillis":180000}]}"#.utf8)
        let discovered = MusicLookup.catalogAlbum(exactCatalog, title: "Song", artist: "Artist", album: "Album", durationMs: 180000)
        precondition(discovered?.id == "123" && discovered?.page?.host == "music.apple.com")
        precondition(MusicLookup.catalogAlbum(exactCatalog, title: "Song", artist: "Artist", album: "Other", durationMs: 180000) == nil)
        let nativePage = Data(#"<script type="application/json" id="serialized-server-data">{"data":[{"data":{"sections":[{"items":[{"id":"album-detail-header - 123","contentDescriptor":{"kind":"album","identifiers":{"storeAdamID":"123"}},"videoArtwork":{"dictionary":{"motionDetailSquare":{"video":"https://mvod.itunes.apple.com/square.m3u8"}}},"tallVideoArtwork":{"dictionary":{"motionDetailTall":{"video":"https://mvod.itunes.apple.com/tall.m3u8"}}}}]}]}}]}</script>"#.utf8)
        precondition(MusicLookup.applePageArtwork(nativePage, albumID: "123", fallback: nil)?.motion?.lastPathComponent == "square.m3u8")
        precondition(MusicLookup.applePageArtwork(nativePage, albumID: "456", fallback: nil) == nil)
        precondition(MusicLookup.applePageArtwork(Data("broken page".utf8), albumID: "123", fallback: nil) == nil)
        let exactArtwork = Data(#"{"name":"Album","artist":"Artist","albumId":123,"animated":"https://mvod.itunes.apple.com/square.m3u8"}"#.utf8)
        precondition(MusicLookup.artworkResult(exactArtwork, title: "Song", artist: "Artist", album: "Album", fallback: nil)?.motion != nil)
        let doubledTimeline = PlaybackTiming.resolve(metadataMs: 240000, streamSeconds: 480, hasVideo: false)
        precondition(doubledTimeline.durationMs == 240000 && doubledTimeline.endTimeMs == 240000)
        let unknownTimeline = PlaybackTiming.resolve(metadataMs: 240000, streamSeconds: .nan, hasVideo: false)
        precondition(unknownTimeline == doubledTimeline)
        let encoderPadding = PlaybackTiming.resolve(metadataMs: 240000, streamSeconds: 241.25, hasVideo: false)
        precondition(encoderPadding.durationMs == 241250 && encoderPadding.endTimeMs == nil)
        let shorterStream = PlaybackTiming.resolve(metadataMs: 240000, streamSeconds: 230, hasVideo: false)
        precondition(shorterStream.durationMs == 230000 && shorterStream.endTimeMs == nil)
        let fullVideo = PlaybackTiming.resolve(metadataMs: 240000, streamSeconds: 480, hasVideo: true)
        precondition(fullVideo == doubledTimeline)
        let genuineLongVideo = PlaybackTiming.resolve(metadataMs: 480000, streamSeconds: 480, hasVideo: true)
        precondition(genuineLongVideo.durationMs == 480000 && genuineLongVideo.endTimeMs == nil)
        precondition(PlaybackTiming.metadataDuration(originalMs: 240000, resolvedMs: 480000) == 240000)
        precondition(PlaybackTiming.metadataDuration(originalMs: 240000, resolvedMs: 241250) == 241250)
        precondition(PlaybackTiming.metadataDuration(originalMs: 180123, resolvedMs: 181123) == 181123)
        precondition(PlaybackTiming.metadataDuration(originalMs: 240000, resolvedMs: 360000) == 240000)
        precondition(PlaybackTiming.metadataDuration(originalMs: 240000, resolvedMs: 359999) == 359999)
        precondition(PlaybackTiming.metadataDuration(originalMs: 240000, resolvedMs: 230000) == 230000)
        precondition(PlaybackTiming.metadataDuration(originalMs: 0, resolvedMs: 480000) == 480000)
        precondition(PlaybackTiming.metadataDuration(originalMs: 240000, resolvedMs: 0) == 240000)
        precondition(PlaybackTiming.metadataDuration(originalMs: -1, resolvedMs: -1) == 0)
        let noMetadata = PlaybackTiming.resolve(metadataMs: 0, streamSeconds: 480, hasVideo: false)
        precondition(noMetadata.durationMs == 480000 && noMetadata.endTimeMs == nil)
        for invalid in [Double.nan, .infinity, -.infinity, -1, Double.greatestFiniteMagnitude] {
            precondition(PlaybackTiming.resolve(metadataMs: 0, streamSeconds: invalid, hasVideo: false).durationMs == 0)
        }
        // The same decision must survive a refreshed URL or promoted crossfade deck.
        precondition(PlaybackTiming.resolve(metadataMs: 240000, streamSeconds: 480, hasVideo: false) == doubledTimeline)
        print("Playback decoding, lyric timing, and lookup metadata tests passed")
    }
}

private actor ArtworkRaceProbe {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false
    func started() { hasStarted = true }
    func cancelled() { wasCancelled = true }
}
