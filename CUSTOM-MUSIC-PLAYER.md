# Custom Apple TV music player

Based on Hk-Gosuto/ytb-music-tv nightly commit 336831f, with custom tvOS presentation and Docker server browsing/playback updates.

## Live animated-artwork background

When animated artwork is available, the player backdrop now uses frames from the same muted AVQueuePlayer that displays the cover. It follows the animation's colors and movement, including loop boundaries, without a second video request or player. Low-resolution samples feed the existing 30 fps blurred warp; a 1.8-second entry fade and short frame blends keep transitions smooth. The existing Balanced layer opacity, dark tint, contrast veil, and still-cover Artwork accents remain in place. The veil follows brightness gradually. Static artwork remains the fallback; pause, backgrounding, and Reduce Motion stop frame sampling. Cover framing and playback/audio resolution are unchanged.

Generation checks reject previous-song frames and prevent a delayed still cover from replacing a live backdrop. Tests cover these lifecycle decisions; the full tvOS SDK workflow compiles the frame-output renderer.

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

## Track-change background continuity

Song loading no longer clears the background image or resets the palette to indigo/purple. Album-cover loading still resets the foreground cover and motion player for correct track identity, while a separate background image remains until the next cover arrives. Initial/no-track fallback is neutral dark. The native warp renderer blends cached blurred covers over 1.2 seconds, preserving motion phase; rapid replacement freezes the current blend before starting a new one. The adaptive veil also animates over 1.2 seconds. Paused/static mode shows new artwork immediately. Syntax and cumulative update checks pass; Core Image SDK build and device transition verification remain required.

## Queue dismissal continuity

Queue uses an in-player overlay instead of a system sheet. The artwork background/warp view remains mounted underneath a neutral dark scrim and panel during opening and dismissal. Underlying controls are disabled/hidden from accessibility while Queue is open; initial focus moves to Done. Done, remote Back and the scrim close the panel and restore Queue focus. Queue row selection still changes songs using the same playback model. Queue retains the native plain List style inside the neutral panel. This removes the system presentation/dismissal path suspected in flashes without a song change. Syntax and cumulative patch checks pass; full SDK build and tvOS dismissal/focus verification remain required.

## Large playlist loading

The TV requests paged playlist responses. For signed-in YouTube TV playlists, the server returns the first page without fetching every continuation. Load more songs appends the next server page; earlier clients retain the original full-playlist API. Carousels render at most 100 songs per view with Previous/Next controls, keeping page state when more songs arrive. The play queue includes all loaded songs, not unloaded pages. Both the IPA and Docker server must be updated to shorten signed-in playlist loading; the carousel limit also works with older servers. Stale browse responses are ignored after navigation. Server continuation tests and Foundation response decoding tests pass; device loading/focus/scroll performance remains to be checked.

## Uncropped animated artwork

The animated cover uses aspect-fit video gravity instead of aspect-fill. This preserves the entire source frame without enlarging it to crop the square cover. Nonsquare animations have neutral black letterboxing inside the existing cover frame once ready; the still cover remains visible while the animation loads. Zoom motion authored into the source animation remains part of that video.

## tvOS Queue build correction

Removes scrollContentBackground(.hidden), which is explicitly unavailable on tvOS. The in-player Queue overlay and continuous artwork background remain in place. Full tvOS compilation is performed by the GitHub build; local Swift syntax checks cannot validate Apple SDK availability.

## Automatic playlist continuation and left controls

The left playback control group moves 45 points toward the edge, matching the existing right group's inset. Playlist carousels request another batch when focus reaches the last ten loaded songs; vertical lists request it when their loading footer appears. The manual Load more songs button is removed. Previous/Next song-page controls retain the bounded 100-card carousel for performance. Concurrent requests for the same continuation token are suppressed; returning focus to the end can retry after an error. Playback queues still contain the songs loaded when playback starts. No additional server update is required beyond v21.

## Complete playback playlists and player refinements

Browsing still requests pages on demand and keeps its 100-card carousel window. When starting a song from a paginated playlist, the selection includes its continuation marker; playback filters that marker out and independently fetches the remaining pages sequentially in the background, appending them to the playback queue without expanding library sections. The Queue shows loading status until complete. Next waits for a forthcoming batch when the current loaded end is reached. Starting a different queue or reconnecting cancels old hydration; a revision prevents late responses appending to a replacement queue. Queue-row selection and regular Next/Previous retain the active hydration task. Network errors are reported rather than claiming the full queue loaded.

Queue uses a ScrollView/LazyVStack with custom artwork-tinted focus backgrounds instead of native List selection styling. Labels stay white with no solid white focus box. Lyric artwork grows from 47% to 53% of screen height (with stage-height bounds) and moves inward 40 points. The left group starts at a 30-point screen inset, uses five equal 48x44 content frames, and 30-point gaps. No new server update is needed beyond v21.

## Restore larger play/pause button

Play/pause restores its original 70x52-point content frame (including the existing button-style padding, its visible box is 102x76 points). Other left controls remain 48x44-point content frames. The 30-point gaps and left group position are retained.

## Wider player progress bar

The progress strip extends 60 points farther toward each edge, reducing its outer screen inset from 90 to 30 points. Its vertical position, opacity and seek behavior are retained.

## Smoother lyrics and final layout refinements

Word highlights interpolate from dim white to artwork accent with a smoothstep fade beginning at each provider timestamp, capped at 0.30 seconds and with a 0.12-second minimum for short words. The existing 50ms song clock drives the fade; line scrolling eases over 0.45 seconds. Line timing and seek behavior are preserved. Tests cover the fade start, midpoint, completion, short words and nonfinite playback time.

The artwork and metadata group moves down 24 points in centered and lyric modes, preserving its 34-point internal gap. Music video layout is unchanged. Each right-side control is visually scaled to 90% within its existing layout frame, retaining the group's position, layout spacing and focus target size; left-side controls keep their existing sizes.

## Top-left artist inset

The top-left artist label moves 30 points closer to the left edge, reducing its screen inset from 90 to 60 points.

## Small left-control nudge

The left playback group moves five points to the right, from a 30-point screen inset to 35 points. Button sizes and gaps are retained.

## Small vertical adjustments

The right auxiliary control group moves down five points. In centered mode, artwork and song metadata move up five points together; the lyric-mode and video-mode artwork positions are retained.

## Tighter right-control spacing

The right auxiliary controls use 20-point gaps instead of 24 points. Their size, vertical offset and trailing alignment are retained.

## Lyric-mode title alignment

Artwork and metadata use a leading-aligned stack in lyric mode, aligning the song title with the left edge of the cover instead of centering the title underneath it. Centered mode keeps its centered alignment.

## Remove lyric close icon

Removes the X button from the lyric header. The Lyrics toggle, remote Back and remote Left exit paths are retained.

## Slightly tighter left controls

The left playback control gaps decrease from 30 to 28 points. The larger play/pause dimensions and leading position are retained.

## Crossfade wave icon and closer left controls

Crossfade uses the SF Symbols waveform icon in the same 48x44-point content frame, 25-point semibold symbol, custom artwork-tinted style and 90% visual scale as the other right controls. Its menu retains the Off and 1–12 second choices, with the current duration exposed as its accessibility value. The visible control no longer shows the selected seconds. Left control gaps decrease from 28 to 24 points; the larger play/pause button is retained.

## Right-aligned tighter auxiliary controls

The right-side control gaps decrease from 20 to 16 points. Trailing alignment is retained, so the group contracts toward the right edge. Icon dimensions and the waveform crossfade menu are retained.

## Boxless right controls gathered toward Crossfade

Lyrics, Video, Queue and Crossfade render without control-box backgrounds, including during focus. Artwork tint, icon focus glow, slight scale feedback, the two-second emphasis timeout and original hit areas remain. Their gaps reduce from 16 to 4 points; the trailing alignment and Crossfade's width remain unchanged, anchoring Crossfade while the other icons gather toward it. Left-control styling is unchanged.

## Faster animated-cover startup

The still-cover download and animation lookup start concurrently. Artwork providers race to return the first validated motion URL rather than waiting for earlier providers to time out. When album metadata is missing, direct song-based providers start immediately while album discovery and enriched lookups run independently. Successful results keep using the existing cache; losing requests are cancelled and artist/title/album validation is retained.

The motion-only AVQueuePlayer uses a one-second preferred forward buffer and requests immediate startup once data permits, while retaining automatic recovery after network stalls. This can trade occasional rebuffering on slow connections for quicker startup; song playback settings are unchanged. Foundation tests exercise first-valid-result selection, cancellation of a slow provider and metadata mismatch rejection. The GitHub build executes these tests and checks tvOS compilation; network and Apple TV startup timing remain to be verified on-device.

## Closer right icons and stronger focus glow

Boxless right controls reduce their horizontal internal padding from 16 to 8 points, bringing icon centers 16 points closer without overlapping focus targets. The right group's trailing inset is compensated by eight points to keep Crossfade's center in its previous position. Their existing four-point external gaps remain. Focused right icons receive a brighter core glow (0.95 opacity, five-point radius), wider halo (0.7 opacity, 18-point radius), subtle brightness boost and 1.10 focus scale. The two-second timeout and boxless appearance remain. Left controls retain their existing padding and glow.

## Centered artwork nudge upward

The centered artwork moves upward eight points independently of the song title. Lyric-mode artwork, song metadata and playback controls retain their positions.

## Matching title styling and boxless left controls

Song titles use the same system font, medium weight and white at 0.75 opacity as the top-left artist label. Existing 34-point centered and 30-point lyric title sizes are retained. All left playback controls remove their box backgrounds while preserving their original content sizes, 16-point horizontal padding, gaps and position, including the larger play/pause button. The artwork-colored icon focus glow and two-second emphasis timeout remain.

## Lower right controls

The right auxiliary control group moves eight points farther down, changing its vertical offset from five to thirteen points.

## Closer boxless left controls

The left control gaps decrease from 24 to 16 points now that their boxes are removed. Larger play/pause dimensions, icon focus glow and leading alignment are retained.

## Search and artist navigation (v45)

Left playback controls move down five points and their gaps shrink from sixteen to eight points. Shuffle retains its horizontal position and every button retains its dimensions.

Search adds All, Songs, Artists, Albums and Playlists category tabs. Playlists includes public/community playlists returned by YouTube Music. Artist results open artist pages with albums and related sections; the Top songs preview expands through YouTube Music's All songs endpoint where available. The top-left artist label opens a menu for View artist or View album, returning to Search while audio continues. Album lookup can recover missing album metadata from an exact song result. Exact destination matching avoids opening an unrelated artist or album.

Opened playlists in Home/Library and Search offer Search this playlist. Queries match titles, artists and albums without case or diacritic sensitivity. The server scans all playlist pages up to its existing 5,000-song safety limit (public playlists additionally bounded to 100 pages), shares concurrent scans and caches snapshots for sixty seconds. Initial large-playlist searches can take time; repeated queries reuse the snapshot. Selecting a match passes the full scanned playback queue, preserving subsequent playback order. Queue search filters the current playback queue as background hydration continues.

Both the v45 Docker server update and TV IPA are required for the new playlist/artist routes. The server updater backs up changed source files and rebuilds only the server service. Forty-eight Node tests verify routing, search caching/retry, full-queue preservation, playlist continuation, artist expansion/fallback and normalization. New Foundation tests cover local matching and response decoding; GitHub Actions runs those and compiles the tvOS IPA. No Apple SDK is available in the local workspace, so device focus, layout and live catalog results still require on-device verification.

## Visible shuffle state (v46)

The Shuffle button shows parallel repeat-style arrows when shuffle is Off, matching the reference arrow design without its circle or colors. When shuffle is On it switches to crossed shuffle arrows. Its 25-point semibold symbol, artwork accent color, original hit area and position stay unchanged. State is driven by the existing playback shuffle flag, so it remains visible after the focus glow times out. Accessibility continues to announce Shuffle On/Off.

## Sharper ordered-playback arrows (v47)

Shuffle Off now uses a custom vector with angular return corners, sharp arrowheads and square stroke caps instead of the rounded system Repeat symbol. Its 25-point bounds, artwork tint, control dimensions and focus styling remain. Shuffle On keeps the crossed shuffle symbol; the dedicated Repeat button is unchanged.

## Song mix and Queue video option (v48)

The right-side Video icon is replaced by an artwork-tinted Mix broadcast-wave icon, using the other compact icons' size, spacing, hit area and focus glow. Selecting it requests YouTube Music's getUpNext Automix recommendations for the current song, preserving current playback while replacing the playlist queue with that song followed by recommendations. Recommendations are not restricted to the seed artist. Loading feedback appears on the button; Queue displays Song mix while active. Shuffle and repeat-one are cleared when the mix starts so recommendations follow their returned order.

The player requests additional recommendations seeded from the last queued song when six or fewer songs remain. It deduplicates already-queued songs, preserves the existing queue on failure, and rejects stale initial requests after a playback change. Choosing a different playlist cancels mix loading; selecting a song from the existing queue retains the mix. Empty recommendations are reported instead of pretending a station started.

Show/Hide music video moves to the top of Queue when video is available. The control returns to the player after toggling. Both the v48 server update and the TV IPA are required for the new Mix route. Fifty Node tests now cover Automix requests, recommendation ordering, different artists, deduplication, metadata, failure propagation and the read-only HTTP route. GitHub Actions provides Swift/tvOS compilation; live recommendation quality, focus behavior and ongoing refill need Apple TV verification.

## Lyric-mode title refinement (v49)

The lyric-mode song title increases from 30 to 32 points and moves six points to the right. Its medium font weight, white 0.75 opacity, vertical position and artwork spacing remain. Centered-mode text is unchanged.

## Minimal lyric title shift (v50)

The lyric-mode title's rightward offset reduces from six to two points for a very small shift. The larger 32-point font remains.

## Artist and album in the header (v51)

Album metadata moves from below the song title into the top-left clickable heading, formatted Artist • Album. Topic channel suffixes are stripped from each artist for display. Missing albums, explicitly Single-labeled releases, and album names matching the song title display only the artist. The metadata does not include authoritative release type, so title equality is a single-detection heuristic. Song titles retain their existing sizes and offsets; the navigation menu still uses original metadata for lookup. Foundation checks cover album, missing metadata, single labels, title matching and multiple Topic artists.

## Tighter left controls and highest available AAC (v52)

Left-control gaps reduce from eight to two points and horizontal internal padding reduces from sixteen to four points. The group leading inset compensates by twelve points so Shuffle's icon center stays fixed while the other buttons gather toward it. Play/pause retains its 70×52 content dimensions; icon sizes and vertical positions remain.

Audio-only playback still selects the highest-bitrate tvOS-compatible AAC stream. Video playback now uses that same best AAC track independently of video resolution, including equal-resolution video or a progressive MP4 as the video source. The existing AVComposition takes only its video track and combines it with the separate AAC track. A progressive stream remains available for playback fallback.

When authenticated TV playback exposes less than 256 kbps AAC, the resolver also asks the YouTube Music endpoint for the same song and adds its audio track only if it is higher bitrate. TV video formats, metadata and methods remain; failed, empty or lower-quality Music responses retain the existing stream. Available Premium quality depends on account entitlements and upstream responses; no new fidelity is created by re-encoding. API resolve responses now include the selected audioBitrate and audioCodec; unknown muxed audio bitrate is null instead of total video bitrate.

Both v52 scripts are required. Fifty-two Node tests pass, including highest-AAC selection, equal-resolution pairing, progressive video with separate audio, no-audio fallback, Music upgrade and failure/no-downgrade cases. The cumulative client updater is checked across earlier builds. GitHub Actions compiles tvOS; real-device sound quality and exposed Premium formats still need verification.

## Bounded quality checks and stream preparation (v53)

The optional Music audio-quality check is limited to one second. A slow, failed or lower-quality response leaves the already-working TV stream in place; late responses cannot modify the formats after selection. The lookup uses getBasicInfo with the Music client rather than getInfo, avoiding its unnecessary concurrent Up next fetch. Highest-bitrate AAC selection remains.

The client also cancels remote video/audio track loading after ten seconds if AVComposition preparation stalls, allowing existing callers to fall back to the regular stream. This bounds these new waits, not total network playback startup. Fifty-three server tests include a stalled lookup and late-result regression. Real TV startup timing and compilation remain verified through the build/device workflow.

## Longer quality-check budget (v54)

The optional higher-quality Music lookup now has a five-second deadline instead of one second. Fast results return immediately; slower requests have more time to expose improved AAC, while stalled requests still fall back rather than delaying playback for minutes. The v53 client track-loading deadline remains. This change needs only the Docker server update if the v53 IPA is installed.

## Title aligned to its cover (v55)

The artwork and song-title frame share the same coverSide value in both layouts. Short titles and wrapped lines center within the artwork width instead of using lyric mode's leading alignment. The existing two-point lyric offset is retained relative to the cover center, with centered mode exactly centered. Cover positions, sizes, title fonts and vertical spacing remain. Video mode retains its unrestricted title layout.

## Centered-mode alignment, audio readout and lower controls (v56)

The shared artwork-width centering applies only in centered mode. Lyric mode retains leading alignment and its two-point rightward title nudge. Left and right control groups move down six points (offsets eleven and nineteen respectively), preserving horizontal placement and spacing.

Queue displays the current selected audio bitrate in kbps beneath its heading. The client decodes the server's audioBitrate field and updates it on manual playback, crossfade and audio fallback. It does not show total video bitrate as audio quality; unknown bitrate, a regular-stream fallback or failed adaptive preparation displays Audio bitrate unavailable. This is a resolver-reported estimate, not measured throughput; server-side proxy recovery may select another upstream stream without client notification. Foundation checks cover available, null and missing bitrate. The server v54 update already supplies this metadata.

## Like the current song from Queue (v57)

Queue's top action row adds an artwork-tinted Like song button with a thumbs-up symbol. It uses the existing authenticated rating route to set LIKE on YouTube, adding the song to Liked Music. After successful acknowledgement the button shows Liked with a filled thumb; selecting it again removes the like. Saving feedback and temporary disabling prevent repeated submissions. Failed requests retain the previous rating and use the existing error banner. Ratings require the already-configured paired TV and writable Google OAuth session; no new server route is needed. Existing server tests cover authenticated likes, removals, pairing and read-only credential rejection.

## Approved midnight-blue app icon (v58)

The Apple TV home-screen icon uses the approved dark navy circle on an OLED-black background, with the rounded white screen box and a single upright music note. The box and note sit higher in the circle; the stem is wider with the final shortened length. Small and large catalog layers, the square master, and the top-shelf image use the same approved raster, exported without stretching. Both icon backdrops are black. Catalog dimensions and asset names remain compatible with the existing build. No server update is required.

## Optional cookie-authenticated Music audio (v59)

Device diagnostics showed HTTP 400 for Music requests carrying TV OAuth tokens. The installed youtubei.js 17 also uses client_type for session initialization; the previously supplied client_name was ignored. TV playback and Library clients now use the correct option. Music playback requests no longer carry the TV OAuth session. Public Music fallback uses getBasicInfo with a five-second limit instead of fetching Up next.

An optional Netscape cookie export at the server data directory's youtube-music.cookies.txt provides a separate WEB_REMIX session for Music audio. YTB_MUSIC_TV_COOKIE_FILE can override the path. Only unexpired root-domain YouTube cookies are imported; unrelated domains and invalid header characters are rejected, and SAPISID is required. Cookie contents never enter public configuration, repository files, or update-script output. Changed or removed files replace or clear the cached cookie client. The separate session reuses the existing signature player without an additional network configuration fetch.

Working TV playback uses better AAC from the cookie session only when its bitrate improves. If TV playback fails, a playable cookie Music response with compatible AAC can supply playback; errors, timeouts, or absent formats retain public fallbacks. Premium membership and actual returned formats still determine available fidelity; 256 kbps is not guaranteed, and Opus/WebM is not transcoded. Existing OAuth Library and rating authentication remain. Fifty-seven Node tests pass, including cookie filtering, separate-session routing, changes/removal, TV failure, unplayable results, and timeouts. Real-account playback remains to be checked. Install the server v59 update; existing v53-or-later TV clients work without a new IPA.

## Bounded playback lookups and cookie diagnostics (v60)

Playback-info resolution has a 20-second overall deadline. TV and public fallback probes are limited to eight seconds each, while the Music quality opportunity remains five seconds. Deadline cancellation reaches network requests through an async request scope; unrelated Library browsing is unaffected. Failed client initialization clears its cached promise so the next attempt can retry. Responses marked OK without compatible audio continue through fallback clients instead of stopping resolution prematurely.

The local check-audio command probes cookie Music and cookie Web playback directly, avoiding the old diagnostic's unbounded public fallback chain. It reports HTTP authentication type, cookie-header presence, direct or nested player status, returned format count, highest AAC bitrate, and the presence of SABR or challenge fields. It does not print credentials, account details, or stream URLs. Sixty Node tests pass, including network cancellation, unaffected browsing, empty playable responses, and safe nested-response summaries. A server-only update preserves the installed cookies and existing IPA. The user's current TV response is UNPLAYABLE with a reload request; actual cookie playback and higher-quality availability still require the new diagnostic on their server.

## Correct large-response audio inspection (v61)

The v60 diagnostic received HTTP 200 from cookie Music and Web but stalled before printing their player status. The checker awaited response.clone().json() before youtubei.js consumed the original response. node-fetch's clone buffers can deadlock on large responses when consumed sequentially; a 250 KB streamed fixture reproduced the stall. The diagnostic now reads the original body once and supplies a buffered replacement response to youtubei.js. Status, headers and body remain available to its parser, with stale transport-encoding and length headers removed. This correction affects diagnostics only and does not establish the account's returned audio quality.

Sixty-two Node tests pass, including prompt large-response inspection, the parser reading the full replayed response, and non-JSON error preservation. The standalone check-music-audio-v61.sh runs the corrected checker in the existing server container using its local credentials, without rebuilding the server or changing the installed IPA. No credentials or response bodies enter the script or its output.

## v62: artist menu, reliable browsing, and broader provider coverage

The top-left artist/album menu now contains View artist, View album, the current stream's reported kbps, and Like/Unlike. The queue retains its music-video action and song search. Likes still use the authenticated YouTube rating route; bitrate still comes from the selected audio format.

Artist/album/playlist category tabs filter the page being browsed instead of launching an empty global search that clears it. Search navigation restores parent headings as well as results. Artist and album browse IDs survive client decoding and playback metadata merging. Related destinations prefer their supplied links, recover from stale links, match alternative IDs only for the same title/artist/recording duration, and consult the exact video's Up next album link. Album-name searches include the artist and normalize Topic suffixes. Live/remix/cover versions are not silently substituted.

Flat youtubei.js NavigationEndpoint payloads and nested thumbnail renderers are normalized. Album tracks without individual covers inherit their album's cover, artist and album links; existing individual covers are preserved. Public playlists can inherit their playlist cover as a final fallback. OAuth TV tiles share the same thumbnail normalization.

LyricsPlus remains the first word-lyrics request, with Apple/Musixmatch/Spotify/QQ preference and staggered mirror requests. LiriQo adds independent access to Apple Music lyric providers, QQ, KuGou, NetEase and YouTube Music line lyrics. Real word/syllable timing wins over line timing; Apple timing is preferred within multi-provider replies. LRCLIB supplies fast line/plain fallback. Synthesized LRCLIB word tracks are excluded. The hosted LiriQo response currently uses milliseconds even though its README describes seconds; both formats are accepted using the recording's duration. Metadata mismatches are rejected. The first usable result is displayed without waiting for another provider; optional lookup never blocks audio playback.

Artwork keeps m8tec, Boidu and NopXx, adds direct Apple Music public album-page motion lookup, and tries exact catalog album URLs/IDs from US and GB song matches. Song title, artist, known album and duration are checked before using a catalog match. Direct page extraction requires the matching album ID and square motion; recommendation and tall artwork are ignored. Successful existing motion caches remain in use. Missing animation or provider failures fall back to the ordinary cover.

Live validation: m8tec returned square motion for Coldplay's Moon Music. Apple's public Moon Music album page exposed matching square motion, and the Swift parser accepted it while rejecting an unrelated album ID. A LiriQo Yellow response supplied real Apple, QQ and KuGou words; Swift validation confirmed usable word timing in seconds. LyricsPlus mirrors can return missing-result/server errors and remain optional fallbacks. Additional providers do not guarantee coverage for every recording.

Verification: 68 server tests pass; Swift 6.2.3 Foundation model/lyric tests, live provider parsing, and syntax parsing of all Swift files pass. The full tvOS SDK compile and device focus/navigation verification run after the GitHub updater. Apply the server updater and client updater, then sideload only the resulting single IPA. Existing local playback cookies and OAuth authorization are preserved.

Provider contracts: https://github.com/AlFarrizi-Studio/LiriQo, https://github.com/ibratabian17/LyricsPlus/blob/cookie/docs/endpoints.md, https://github.com/m8tec/apple-music-animated-artworks, https://github.com/boidushya/artwork.boidu.dev, https://github.com/NopXx/apple-music-artwork-search.

## v63: inflated audio duration and silent tail

Audio-only streams with a container duration at least 50% (and at least ten seconds) longer than the known song duration now use the song duration for progress, seeking and crossfade timing. AVPlayerItem.forwardPlaybackEndTime ends the inflated timeline at that same point, allowing the existing end observer to advance or repeat rather than wait through a silent tail. The boundary is also applied to prefetched crossfade decks and refreshed fallback items. Unknown audio duration initially uses the metadata endpoint; finite normal duration clears that provisional limit. Small encoder differences, genuinely shorter streams, and video timelines retain their actual stream duration. Without song metadata, the finite stream duration remains the fallback.

Replacing items or promoting a crossfade deck invalidates the previous periodic-observer generation, so delayed callbacks cannot write an old clock into a new song. Timing refresh avoids publishing an unchanged duration every 50 ms.

Swift Foundation regression tests cover a doubled four-minute timeline, unknown duration, small encoder padding, shorter streams, video length, missing metadata and non-finite/overflowing values. These tests and Swift syntax parsing pass locally. The full tvOS build and the originally reported silent-tail symptom require the new IPA to be built and checked on-device. This is a client-only update; the v62 server and cookies remain in use.

## v64: global Search recovery and animated-cover matching

Submitting a nonempty query from an artist or album page now starts a global search in the selected category. The artist/album page flag no longer blocks the request, and typing a new global query no longer filters the old browse page into an apparent empty result. With an empty query, category tabs still filter the browsed page. The last successful global query and category are retained when returning from related pages or reopening Search. Submission captures the text/category before launching its task; Back invalidates pending search results so an older response cannot replace the restored page. Playlist-local and queue search remain separate.

Artwork title matching ignores parenthesized, bracketed and trailing feat./ft./featuring credits, including differences between a YouTube title and Apple's track title. This normalization is confined to artwork matching and queries; lyric recording checks remain in place. Unicode Topic suffixes are removed alongside the existing ASCII suffix. Wrong artists, different titles, live/remix versions and incompatible catalog durations are still rejected. Known album names continue to restrict catalog matches.

The catalog lookup deduplicates matching album IDs and tries up to three compatible releases in each existing US/GB lookup rather than stopping at the first catalog record. Each release can use m8tec, Boidu, NopXx and Apple's own matching public album page. The direct provider requests continue in parallel, and the first valid animation cancels outstanding work. Missing/failed providers cannot cache a static-only answer, and audio playback does not wait for artwork.

Live checks found that both Boidu and NopXx return motion for Post Malone's rockstar (feat. 21 Savage), which the prior exact title comparison rejected for Rockstar. The updated Swift parser accepts both real replies for Rockstar. The catalog recovers beerbongs & bentleys as the first matching album and additional compatible releases. The m8tec motion manifest and Boidu motion URL both returned HTTP 200.

Swift Foundation tests pass for featuring-credit variants, wrong artists, live/remix titles, duplicate catalog releases, album/duration restrictions, failure of one provider while another succeeds, and existing playback/lyric timing. Syntax parsing of all Swift files and Foundation/API type checking also pass. The full tvOS SDK compile runs through the updater's GitHub build; Search focus/navigation and animated playback still require checking with the new IPA on Apple TV. This client-only cumulative update includes v63's duration/silent-tail correction and keeps the v62 server, high-quality audio setup and approved icon.

## v65: compact right controls and Mix in the artist menu

Start song mix moves from the right playback-control row to the top-left artist/album menu, following the Like action. It uses the same mix request and current-song seed, indicates loading in its label, exposes the active state to accessibility, and is disabled while loading, preparing playback or lacking a playable video ID. Queue retains its existing mix/loading indicators.

The right row now contains Lyrics, Queue and Crossfade. Its spacing is zero and Lyrics/Queue use two points of horizontal padding per side instead of eight, bringing their icons toward Crossfade without changing glyph size. Crossfade remains the final trailing item with its existing width, scale, trailing padding and vertical offset, so its position is preserved as the row becomes narrower. Left controls and all other player layout remain unchanged.

All Swift sources pass syntax parsing. This small UI adjustment adds no new model tests; the full tvOS SDK build runs through the updater, and spacing/focus and menu actions require verification on Apple TV. The cumulative client-only updater includes the preceding Search, artwork and duration fixes. No server update is needed.

## v66: slight right-control adjustment and stronger song-end timing

The right row moves down four points (offset 23), uses two-point spacing, and scales its icons from 0.90 to 0.88. Glyphs are slightly smaller while focus styling, hit frames and the Mix menu placement remain.

The previous duration guard skipped streams marked as video. It now bounds any clearly inflated stream timeline against the known recording duration, including video-capable playback behind album art. Merging a playback response also preserves the existing song duration when the response itself is at least 50% and ten seconds too long; normal padding, shorter recordings and absent metadata retain the existing safe fallbacks. A genuinely long recording with matching metadata is not halved.

A periodic end check complements AVPlayerItem.forwardPlaybackEndTime and the natural end notification. Both completion paths share a per-item guard, preventing duplicate next-song requests. Repeat/seek re-arms completion after playback actually moves below the end; replacement and crossfade promotion clear the old completion marker. Outstanding track changes and active crossfades prevent the old item from advancing the queue again. Metadata-based detection cannot infer the true length when every supplied duration is wrong or missing.

Foundation regressions cover video-capable inflated timelines, genuine long videos, inflated resolved metadata, encoder padding, shorter streams, missing/negative metadata and prior playback/lyrics checks. Full Swift tests and tvOS compilation are run in GitHub Actions for this client-only change; device playback still requires the new IPA. No server update is needed.

## v67: smooth idle hiding for playback controls

After eight seconds without interaction, the left/right playback controls and the entire progress strip (including times and knob) fade out over 350 ms. Remote movement, focus entry, selection, Play/Pause, progress interaction and lyric browsing reveal them with a 120 ms fade and restart the deadline. The existing two-second focus-glow timeout remains. Each activity revision cancels the previous timer, so an older timer cannot hide newly revealed controls.

Only the drawings inside the button styles and progress label fade; their views, focus frames and layout remain in place. Artwork does not shift when controls disappear. Scrubbing, Queue, loading, inactive scenes and VoiceOver prevent idle hiding; exiting those states restarts the deadline. Reduce Motion uses immediate visibility changes. Automatic progress and lyric ticks do not repeatedly wake the controls; playback-status and loading changes reveal them for feedback. The title, artist menu, artwork and lyrics remain visible; this feature reduces exposure of static controls and does not guarantee protection against OLED burn-in.

This client-only UI change is validated by the existing regression suite and full tvOS build in GitHub Actions. Remote focus, menus, scrub interaction and fade appearance still require an on-device check with the new IPA. No server update is needed.
