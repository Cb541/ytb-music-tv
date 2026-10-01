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

The new presentation uses HTTPS requests to artwork.m8tec.top (when album metadata exists), artwork.boidu.dev, lrclib.net, and the LyricsPlus HTTPS mirrors (binimum.org and prjktla.workers.dev). Those requests send song/artist/album metadata. Availability and accurate animated-cover/lyric matches depend on those services. Cover art remains static when there is no working animated match. Lyrics use real word/syllable timestamps when the provider supplies them; ordinary LRC remains line-level. The crossfade is a fixed-duration equal-power overlap, not Orchard's tempo/beat-matched AutoMix.

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

## Presentation refinement

The active synchronized lyric uses the same artwork accent as the transport controls, with two soft glow layers and a short highlight transition. The background samples a 48-pixel sRGB cover, balances color coverage with chroma, preserves sampled hues, and modestly lifts brightness/saturation. It retains neutral palettes for neutral artwork. Ordinary alpha blending replaces screen blending to avoid washing out colors, and the dark overlay is reduced from 27% to 18%. Swift syntax parsing passes locally; visual balance still needs device review.

## Expanded motion artwork lookup

Adds apple-music-artwork.nopxx.site as a third square-motion provider, alongside m8tec and boidu. Uses the public iTunes song catalog to recover missing album names with artist/title/duration checks. Album comparison tolerates Deluxe/Expanded/Remastered edition labels while preserving Live versions. Boidu requests now include known album and duration. All providers use validated HTTPS MP4/MOV/HLS motion URLs; still images and album-page URLs cannot become motion inputs. Matching preserves artist and song identity. Successful artwork is cached per artist/album, and failed lookups are not cached as permanent static-only results. These services receive artist/title/album metadata; iTunes discovery also receives duration matching locally.

Live checks returned HTTP 200 from m8tec, Apple's iTunes catalog and NopXx. Swift parsing of m8tec and NopXx responses both matched square motion for Coldplay's Moon Music. Expanded model tests cover provider result shapes, rejecting wrong artists/tracks/albums, recovering an album, edition labels and non-video URL rejection. Device playback and the new full SDK build remain to be checked.

Provider contracts: https://github.com/boidushya/artwork.boidu.dev, https://github.com/m8tec/apple-music-animated-artworks, https://github.com/NopXx/apple-music-artwork-search.

## Queue artwork

The Now Playing queue uses the existing static artwork thumbnail component: 80-point square covers with rounded corners beside each song. Missing/failed images retain a music-note placeholder. Artwork is decorative for accessibility and stays inside the existing row button so queue selection and tvOS focus behavior remain the same.

## Balanced artwork warp and word lyrics

Investigated the supplied Orchard 5.0.0-beta.9 source: appearancePreferences.js sets Balanced to 0.82 opacity; KawarpArtworkBackground.js uses animation speed 1.38, saturation 1.24, scale 1.32, tint [0.024, 0.04, 0.028] at 0.42 intensity, and warp intensity 0.92. immersiveVeil.js sets a 0.34 veil floor, 0.82 ceiling, and contrast targets 4.5/3. The native background now uses these intensity/scale/tint settings and a sampled adaptive veil. Core Image performs moving twirl/bump distortion on a cached blurred cover, rather than drifting palette blobs. Render resolution is 480x270 at 30fps; blur is baked once per cover. This is an independent native analogue, not the exact Kawarp shader or a pixel-identical port. Motion stops when playback pauses, the scene is inactive, or Reduce Motion is enabled.

LyricsPlus line/word/syllable timestamps and durations are preserved, excluding background vocals from the main lyric. The active line highlights fragments as their real timestamps pass. Invalid/mismatched word text falls back to the intact line. LyricsPlus is searched even when LRCLIB already has line sync; available line lyrics appear immediately and upgrade when a word result arrives. The pane labels word results WORD SYNC. The playback observer runs every 50ms while Now Playing metadata updates at second boundaries. No word timings are invented for plain LRC. LyricsPlus-seven.vercel.app is an additional fallback mirror.

Validation: Foundation tests cover exact word starts/ends, inferred end bounds from subsequent word/line timestamps, string timestamps, spacing, ignoring adlibs, line text mismatch and plain/line fallback. Foundation type checking and all Swift syntax parsing pass. Core Image compilation/playback needs the Actions build and Apple TV review; provider availability still governs word coverage.

## Centered cover and bare progress bar

Centered artwork grows to fit the available stage, reserving space for song metadata; the lyric layout keeps its existing cover size. The music layout removes the progress strip glass rectangle and places the bare strip below transport controls near the bottom, with a 22-point bottom margin. The reusable progress component keeps its original default background for other screens. Existing scrubbing hit area, remote handling, focus feedback and time labels remain available. Swift syntax and update compatibility checks pass; device layout still needs review.

## Lyrics without button boxes

Lyric rows use the existing label-only remote button style with the native focus effect disabled, removing tvOS backplates. A focused row brightens its text slightly; pressing still seeks to real line timing. Synchronized color/glow remains tied to playback.

## Header cleanup

Removes the top Now Playing heading and Library button from the music screen. The existing remote Back/Exit handler still returns to the library, dismissing the queue/video first when applicable. Playback preparation is indicated on the cover rather than in a header row.

## Artist header and consistent control opacity

Artist appears at top left and is removed from the metadata beneath the cover. A matching Artist - prefix is stripped from the displayed title and lookup title; unrelated hyphenated titles remain intact. Lyrics uses the same 0.16 artwork-accent background opacity as Queue even when enabled. Crossfade picker uses the same bordered styling and tint opacity. The centered cover reserves less metadata space after moving the artist. Title-prefix tests, Swift syntax and cumulative update checks pass.

## Idle control highlight

Play/Pause now uses the same 0.16 artwork-accent background opacity as Queue, Lyrics and Crossfade. Transport buttons use a custom visual focus indicator rather than a native permanent backplate. A cancellable two-second inactivity task fades the focus outline/glow/scale while preserving the focused control. Focus movement, remote directional commands, button activation, play/pause commands, crossfade selection and scrubbing activity restore emphasis and restart the deadline. Selected shuffle/repeat state remains separate from focus emphasis. Swift syntax and cumulative patch checks pass; device focus/navigation verification remains required.

## More transparent controls

All ordinary player control boxes now use 0.08 artwork-accent opacity instead of 0.16. Enabled shuffle/repeat backgrounds are reduced from 0.65 to 0.20, retaining state indication without a heavy fill. Icon color and idle focus behavior remain the same.

## Lyric navigation and quieter progress track

In lyric mode the cover/title group aligns to the left edge of its column instead of the center, shifting it farther left. Back closes lyrics before leaving the player; Left from lyric rows also closes them, and the lyric header has a Close button. Closing returns focus to Lyrics. Manual browsing pauses follow only temporarily: after three seconds without another row move, the pane returns to the active line. Selecting a timed line or Follow song resumes immediately. While following, row focus advances with the active line so tvOS cannot keep an obsolete row pinned in view. Bare music progress uses 0.12 unplayed opacity (0.18 focused, 0.26 scrubbing), while other progress screens keep their old defaults. Syntax and cumulative update checks pass; device focus/scroll verification remains required.

## Focus highlight without outline

Removes the white focus outline from player control buttons. Focus instead slightly brightens the artwork-accent fill, adds a soft accent glow and retains the small scale emphasis. The existing two-second inactivity deadline and focus-preserving behavior remain unchanged.

## Cover/title spacing

Increases the gap between album artwork and song metadata from 22 to 34 points, a modest 12-point adjustment in both centered and lyric layouts.

## Right-side control grouping

Lyrics, Music Video, Queue and Crossfade share a trailing HStack with 24-point gaps. The group shifts 45 points toward the screen edge. Crossfade uses its intrinsic width instead of a 210-point outer frame so that unused width does not create an uneven visual gap. Music Video remains conditional on video availability.

## Music video cover layering

When the music video is active, the artwork view is removed from the layout and its motion player is dismantled. Song details sit at the bottom of the video stage above controls. Turning video off restores the regular centered/lyric cover. The same audio/video AVPlayer continues playing.

## Played lyric blur

Synchronized lyric rows before the current line receive a soft 3-point blur with a 0.25-second transition. The active and upcoming lines remain sharp. Blur is applied to the text inside the existing row button, preserving hit areas and accessibility. Seeking recalculates played rows from the actual active line. Untimed lyrics stay sharp.
