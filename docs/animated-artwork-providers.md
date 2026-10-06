# Animated artwork resolution (v69)

The player prefers square Apple Music motion artwork. It keeps the existing still cover when no verified animation is available.

Priority is based on origin, exact release matching, and the observed reliability of a small probe set, not a claim of universal coverage:

1. Apple motion catalog (new direct AMP lookup for a validated album ID).
2. Apple album page (independent public page parser for that same ID).
3. Boidu.
4. NopXx.
5. m8tec.

Direct song searches run alongside Apple release discovery so catalog discovery cannot hold up an available animation. Hosted fallbacks start 350 milliseconds apart, in ranked order. The first valid animation cancels remaining work. This is a staggered race rather than waiting through every provider's full timeout.

Apple release discovery checks the US, UK, Canada, and Australia. Later storefronts start only after a delay and are cancelled when an earlier route succeeds. Exact artist/title/version/duration matching and the three-release-per-storefront bound remain in place. The direct catalog accepts square variants belonging to the requested album ID and never borrows motion from recommendations or substitutes portrait artwork.

The anonymous token embedded in Apple's web player is cached for 30 minutes and refreshed after a rejected catalog response. It is not an Apple Music subscriber credential. This is an unofficial web-catalog integration and can change independently of the app.

## Investigation on October 6, 2026

- Boidu and NopXx returned working motion URLs for Rockstar by Post Malone and Last Thing You Need by Morgan Wallen.
- m8tec returned motion for beerbongs & bentleys and After Hours, but was slower and timed out for the GTA VI soundtrack in this sample.
- Direct Apple AMP returned square and tall motion for the GTA VI album; the player selects square.
- Orchard's artwork endpoint returned HTTP 502 for all three song probes and a direct album-ID probe. It was not enabled as a production dependency.
- Cider AniArtwork converts existing Apple motion to GIF/WebP; it does not supply another independent cover catalog.
- Spotify Canvas is a track-specific portrait video, not a square animated cover. The inspected implementations need Spotify authentication.
- TIDAL supports motion covers, but its public album HTML did not expose them in the checked sample; its catalog integrations require separate credentials. No account setup was added.

Useful references:

- https://github.com/NopXx/apple-music-artwork-search
- https://github.com/boidushya/artwork.boidu.dev
- https://github.com/m8tec/apple-music-animated-artworks
- https://github.com/InstaZDLL/waveflow-plugin-apple-artwork
- https://github.com/ciderapp/AniArtwork
- https://github.com/SFG5453/Orchard
- https://github.com/Paxsenix0/Spotify-Canvas-API
