# Custom Apple TV music player

Based on Hk-Gosuto/ytb-music-tv nightly commit 336831f. The Docker server is unchanged.

## Changes

- A SwiftUI Now Playing screen with a large square cover, title and artist, album-derived animated background, progress scrubber, transport controls, queue, and lyrics toggle.
- Muted looping album artwork from the artwork providers used by the supplied Orchard reference. The ordinary cover remains visible until the motion player's layer is ready. Artwork lookup is optional and never blocks playback.
- LRCLIB timed lyrics, multiple timestamps per LRC line, timing offsets, automatic scrolling, manual browsing, and selecting a timed line to seek. Plain lyrics and an unavailable/instrumental state are supported. Synced search results are preferred over plain exact results. Artist accents and featured-artist formatting are normalized; matches with a duration difference over 12 seconds or a different title/version are rejected. LyricsPlus is a secondary timed source.
- Crossfade between ready adjacent queue entries, selectable from Off to 12 seconds, with a 5-second default. The incoming deck must start before the old deck fades. Track identity, lyrics clock, Now Playing metadata, and time observers move to the incoming deck together. Pausing pauses both decks; seeking, skipping, changing queue mode, and starting another track cancel the overlap. Repeat-one bypasses crossfade.
- Native root safe-area override retains fullscreen backgrounds and video. Controls retain margins.
- Tolerant decoding of optional playback URLs and media metadata, a usable direct/proxy URL requirement, an explicit preferVideo query on resolution, and field-specific response errors. Video preference OFF skips adaptive video composition.
- A settings switch preserves access to the original video-oriented player.

## External services

The new presentation uses HTTPS requests to artwork.m8tec.top (when album metadata exists), artwork.boidu.dev, lrclib.net, and the LyricsPlus HTTPS mirrors (binimum.org and prjktla.workers.dev). Those requests send song/artist/album metadata. Availability and accurate animated-cover/lyric matches depend on those services. Cover art remains static when there is no working animated match. Lyrics timing is line-level, not word-level. The crossfade is a fixed-duration equal-power overlap, not Orchard's tempo/beat-matched AutoMix.

The Orchard source was used as a reference for provider contracts and feature behavior. The new tvOS implementation is written in Swift and does not copy or embed Orchard's Electron audio engine, Vue components, or JavaScript modules.

## Build

The `Custom Apple TV Music Player` workflow builds the checked-out branch on macos-26, first runs the Foundation decoding/lyrics tests, then compiles all Swift files and uploads an unsigned IPA. It does not publish a release.

From Fedora, install `gh` and `unzip`, extract the source archive, then run `bash build-on-github.sh`. It authenticates with GitHub if needed, verifies or creates your fork, enables Actions on that fork, pushes a separate custom branch based on nightly 336831f, waits for the macOS build, and downloads the unsigned IPA to `built-ipa/`. It preserves the fork's main branch. A terminal command is provided because the GitHub plugin's repository and Actions tools remain unavailable here even after retrying a new turn.

Local macOS build:

```bash
bash client-tvos/test-models.sh
OUTPUT_IPA="$PWD/YTBMusicTV-custom-music-player-unsigned.ipa" bash client-tvos/build-ipa.sh
```

The IPA must be signed before device installation, using the same method as the original unsigned nightly.

## Verification status

Passed locally: Swift Foundation tests for malformed optional adaptive URLs, malformed direct URLs with usable proxies, absent/default media fields, duration strings, malformed optional metadata, Codable round trips, a response with no usable playback URL, multiple LRC timestamps, fractional times, timing offsets, instrumental lyrics, unsynced lyrics, and active-line selection. The Models, APIClient, MusicLookup, and MusicLyrics files also pass Swift type checking. All Swift files pass syntax parsing; the shell scripts and workflow parse successfully.

The first build passed the full tvOS compile in Actions run 36821263903. Device feedback confirmed music, automatic advancement, crossfade and plain lyrics; manual Next crashed. This revision creates a fresh AVPlayerItem from the cached asset on manual skips, centers artwork until lyrics open, colors transport/progress highlights from the artwork, and replaces the faint ambient ellipses with three moving radial color fields. This revision still needs an Apple SDK build and device verification. Local Swift model tests and syntax parsing pass; live LyricsPlus probes encountered provider access/rate-limit errors, so external fallback availability remains unverified.

On Apple TV, check video preference ON and OFF, switching songs rapidly, animated/static art fallback, pause/resume, lyric toggling/seeking, manual lyric scrolling and Follow song, repeat-one, shuffle, crossfade cancellation on seek/skip, automatic queue advancement, and fullscreen layout.
