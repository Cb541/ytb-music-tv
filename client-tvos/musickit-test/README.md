# MusicKit Atmos Test for Apple TV

This is a standalone diagnostic app. It does not replace the YTB Music TV app,
change the Docker server, or resolve Apple Music songs into YouTube streams.
All full-track audio uses native `ApplicationMusicPlayer`.

## Account setup

1. Sign into Apple Music on the Apple TV with an active subscription.
2. Register an explicit App ID in your Apple Developer account for the bundle ID
   used to sign this app. Its default ID is `com.cb541.ytbmusickit.atmostest`.
3. Enable **MusicKit** under that App ID's **App Services**. Apple associates this
   runtime service with the signed bundle ID and generates developer tokens.
   This Swift integration needs no hand-written developer JWT or private key in
   the app. Do not add undocumented MusicKit entitlements.
4. Sign and sideload the unsigned IPA with that registered identity. If your
   signing tool changes the bundle ID, enable MusicKit for the final ID instead.
   The app displays its actual bundle ID.

Apple's setup documentation:
https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api

## Device test

1. Set Apple TV **Settings > Apps > Music > Dolby Atmos > Automatic**.
2. Use an Atmos-compatible TV, soundbar/receiver or supported audio output.
3. Open **MusicKit Atmos Test** and choose **Connect / check account**. Accept
   the system Apple Music permission prompt.
4. Search for a song whose particular catalog version you know has an Atmos mix,
   or enter its Apple Music song URL / numeric song ID.
5. Select a result and wait for playback. Watch **MusicKit active audio**.
   **Dolby Atmos** in green means MusicKit reports the active Atmos variant
   while playing. The catalog-availability line is separate and never qualifies
   a track as actively playing Atmos by itself. A nil variant remains unknown.
6. Confirm the audible output with your audio equipment too. The app route is
   informational; it is not a receiver-format measurement. The device may render
   differently depending on output capability. Receiver badges alone can also
   be misleading with Apple TV's continuous Dolby MAT connection.

Apple explains active variant reporting:
https://developer.apple.com/videos/play/wwdc2022/110347/

No previews, upmixing, DSP, crossfade, or alternative audio providers are used in
this diagnostic. Apple selects audio quality from device/user settings and
network conditions; the app cannot force an Atmos variant through an unsupported
output. Search does not start playback until a result is selected.

If account, catalog or playback access fails, the app displays the failing stage
and error domain/code. A developer-token failure usually requires checking App
Services, the final signed bundle ID and signing team before blaming the audio
decoder. Do not send passwords, private keys or tokens in troubleshooting logs.

## Build

On a Mac with the tvOS SDK:

```bash
bash client-tvos/musickit-test/build-ipa.sh
```

The isolated GitHub workflow runs Foundation checks and compiles against the
actual tvOS SDK, then produces an unsigned IPA for device testing. CI compilation
does not prove subscription access or Atmos output on a real Apple TV.
