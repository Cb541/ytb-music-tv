# Still-cover audit (2026-10-08)

## Confirmed defects

- Playback metadata merge replaced the square catalog cover, album and artist with the YouTube player response even for a catalog song whose video ID did not change. Player responses can contain video thumbnails rather than album art.
- Still images were accepted based on pixel count alone: no aspect-ratio, thumbnail-host or embedded-letterbox checks. Increasing CDN dimensions is not evidence of source detail.
- Anonymous Apple catalog searches used a four-second timeout. Four independent live lookups in this environment took 5.86–6.23 seconds, so valid results were discarded.
- Still lookup canceled other requests as soon as metadata returned a URL. A corrupt, unavailable, rectangular or tiny first image prevented attempts to use other legitimate releases.
- Static fields from animation providers could replace the selected still image.

## Implemented behavior

- Keep title, artist, album and cover from a catalog song when merging stream metadata. Preserve rating and playback/timing handling.
- Use matching Apple song/album catalog art for still images; third-party artwork services supply animation only.
- Request metadata and the existing Music cover concurrently. Metadata and image requests get ten seconds, independently of audio resolution.
- Require exact artist/song identity and compatible duration for recording-based cover fallback, rank the specified album first, and retain different live/remix titles as different recordings. An album-name discrepancy no longer blocks an otherwise exact recording match.
- Continue the lookup until an image has actually decoded and validated. Try up to four distinct covers per response and US/GB/CA/AU catalogs.
- Block YouTube video-thumbnail URLs. Require essentially square images and minimum decoded dimensions of 800 pixels for catalog sources or 600 for Music thumbnails. Detect symmetric black video padding on unverified thumbnails, while preserving intentional black negative space in verified catalog designs.
- Decode/downsample off the UI actor to a maximum 1200-pixel edge without enlarging small originals. Do not crop, zoom, stretch or invent image details.
- Cache successful validated catalog images with a 48 MiB cost limit. Never cache an outage as a permanent miss.
- If no acceptable cover is found, use the existing neutral artwork placeholder instead of a video frame or tiny thumbnail. Animated-art playback is retained.

## Live audit

Downloaded and visually inspected Apple catalog covers at 1200 × 1200:

| Artist | Recording | Cover |
| --- | --- | --- |
| Cosmonkey | Miami Beach | Road to Summer |
| AC/DC | Highway to Hell | Highway to Hell |
| Post Malone | rockstar (feat. 21 Savage) | beerbongs & bentleys |
| Pink Floyd | Comfortably Numb | The Wall |

Images were fetched in 3.3–3.4 seconds in this environment. These measurements do not establish timings on the user's Apple TV/network. No copyrighted cover image is bundled with the application or tests.

## Regression coverage

ImageIO tests generate image data and exercise: a valid square cover, a rectangular image, a square video padded with black bars, a tiny image, corrupt data, video-thumbnail URLs, legitimate black album art, preservation of catalog art during stream merging, and failover after a rejected first URL. Existing playback decoding, duration, artwork matching and lyric-timing tests continue to run.

## Limits

No automatic image-sharpness heuristic can perfectly distinguish intentional soft artwork from a low-detail source. Source identity and actual decoded geometry are used instead. Catalog outages and albums without acceptable source art can produce a placeholder; this avoids displaying an unsuitable substitute.


## v79: Recovering legitimate covers after over-filtering

The v78 minimum of 600 decoded pixels rejected valid native 512/544-pixel Music album covers. Also, legacy iTunes search did not return the actual recording for live US queries for MOJO JOJO, Euro$tep and BAD NEWS, while the current Apple Music catalog did. Shared credits (for example ¥$, Kanye West & Ty Dolla $ign) and omitted apostrophes could further prevent matching.

- Add current Apple Music catalog search alongside legacy iTunes search. Validate artist credits, recording title/version, duration and decoded dimensions before accepting an image.
- Match complete artist-credit tokens rather than requiring the first catalog artist to equal the first Music artist; normalize apostrophe differences for cover titles. Do not accept substring artist matches or alternate live/remix titles.
- Recover the original Music album header through read-only album browsing when no image is available. The server returns a dedicated optional albumArtworkUrl containing only that header, without substituting input playback or track thumbnails. This request does not change Search navigation or audio resolution.
- Accept native square Music/album images of at least 512 pixels; still reject tiny images, rectangular video frames and square video thumbnails containing letterbox bars. Video-host images are eligible only when supplied by the album header, and still undergo decoded shape/bar checks.
- Keep catalog images at the 800-pixel minimum. Request 1200-pixel CDN variants; never crop, stretch, or upscale decoded images. A native fallback cannot replace or cache over a higher-ranked catalog image, and a cached native fallback does not prevent catalog upgrades on later playback.

Live current-catalog queries fetched and visually inspected 1200 × 1200 covers for MOJO JOJO / Playboi Carti, Euro$tep / Eddy West, Invincible / Aminé, Don't Need Friends / NAV and BAD NEWS / Aries. A VULTURES / Kanye West query also returned a 1200 × 1200 cover, but the user's "Vultures Topic" wording does not establish that exact artist/version. These checks prove provider availability in this environment, not playback on the user's Apple TV. No downloaded cover image or public web token is bundled or committed.

Regression coverage adds native 512/544-pixel images, rejection of tiny/rectangular/letterboxed album thumbnails, current-catalog parsing and version/artist/duration rejection, joint artist credits, apostrophe variants, old-server response compatibility, and dedicated album-header selection when a track has a separate video thumbnail.
