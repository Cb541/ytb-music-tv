import { Innertube, Parser, Platform, UniversalCache, YTNodes } from 'youtubei.js';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { AsyncLocalStorage } from 'node:async_hooks';

const playbackRequestScope = new AsyncLocalStorage();

import {
  bestThumbnailUrl,
  normalizeMediaNode,
  normalizeSearch,
  normalizeSection,
  normalizeTrackInfo,
} from './media-normalizer.js';

Platform.shim.eval = (data, env) => {
  const properties = [];
  if (env.n) properties.push(`n: exportedVars.nFunction("${env.n}")`);
  if (env.sig) properties.push(`sig: exportedVars.sigFunction("${env.sig}")`);
  const code = `${data.output}\nreturn { ${properties.join(', ')} }`;
  // youtubei.js requires a host-provided evaluator for player signature functions.
  return new Function(code)();
};

export class YouTubeMusicService {
  #configStore;
  #sessionStore;
  #oauthLibraryService;
  #fetch;
  #clientPromise;
  #playbackClientPromise;
  #cookieClientPromise;
  #cookieHeader = '';
  #cookieFile;
  #clientFactory;
  #cookieWarning = false;
  #streamCache = new Map();
  #streamInflight = new Map();
  #playlistSearchCache = new Map();
  #officialSongCache = new Map();

  constructor({ configStore, sessionStore, oauthLibraryService = null, fetchFunction = globalThis.fetch,
    cookieFile = join(process.env.YTB_MUSIC_TV_DATA_DIR ?? new URL('../../data', import.meta.url).pathname, 'youtube-music.cookies.txt'),
    clientFactory = (options) => Innertube.create(options) }) {
    this.#configStore = configStore;
    this.#sessionStore = sessionStore;
    this.#oauthLibraryService = oauthLibraryService;
    this.#fetch = (input, init = {}) => {
      const scopeSignal = playbackRequestScope.getStore();
      if (!scopeSignal) return fetchFunction(input, init);
      const requestSignal = init.signal ?? input?.signal;
      const signal = requestSignal ? AbortSignal.any([requestSignal, scopeSignal]) : scopeSignal;
      signal.throwIfAborted();
      return fetchFunction(input, { ...init, signal });
    };
    this.#cookieFile = process.env.YTB_MUSIC_TV_COOKIE_FILE ?? cookieFile;
    this.#clientFactory = clientFactory;
  }

  authStatus() {
    const session = this.#sessionStore.get();
    const oauth = this.#oauthLibraryService?.authStatus() ?? { status: 'not_configured' };
    return {
      mode: 'google-device-oauth',
      status: oauth.status,
      hasCookie: Boolean(this.#cookieHeader),
      hasOAuthToken: Boolean(oauth.hasRefreshToken),
      hasPoToken: Boolean(session.poToken),
      hasVisitorData: Boolean(session.visitorData),
      musicLibraryStatus: oauth.status,
      error: oauth.error ?? null,
      updatedAt: oauth.updatedAt ?? null,
    };
  }

  async search(query, filters = {}) {
    const client = await this.#client();
    const result = await client.music.search(query, filters);
    return normalizeSearch(result);
  }

  // Only redirect video/unknown entries without an album. Catalog songs need no extra request.
  async officialSong(media) {
    if (!media?.videoId || !media.title || !media.artist ||
        (media.type === 'song' && media.albumBrowseId)) return media;
    const key = media.videoId;
    const cached = this.#officialSongCache.get(key);
    if (cached && cached.expires > Date.now()) return await cached.promise;
    const promise = (async () => {
      const source = { ...media };
      if (media.type !== 'song') {
        // In music playback, replace performance videos with the official studio song.
        source.title = studioVideoTitle(media.title);
        source.durationMs = 0;
        const parts = source.title.split(/\s+[-–—]\s+/);
        if (parts.length > 1) source.artist = parts[0];
      }
      const result = await boundedMusicInfo(() => this.search(
        [musicTitle(source.title, primaryMusicArtist(source.artist)), primaryMusicArtist(source.artist)].join(' '),
        { type: 'song' }), { timeoutMs: 5000 });
      const candidates = result?.sections?.flatMap((section) => section.items) ?? [];
      // Require song catalog metadata and exact recording identity. Never choose a fuzzy first result.
      // Videos can have long intros/outros; duration is not recording identity here.
      if (media.type === 'video' || /official\s*(?:music\s*)?video/i.test(media.title)) source.durationMs = 0;
      return candidates.find((item) => item.type === 'song' && item.videoId && item.albumBrowseId &&
        sameRecording(item, source)) ?? media;
    })().catch(() => media);
    if (this.#officialSongCache.size >= 500) this.#officialSongCache.clear();
    this.#officialSongCache.set(key, { promise, expires: Date.now() + 10 * 60 * 1000 });
    return await promise;
  }

  async playlistSearch(media, query) {
    const id = media?.playlistId ?? media?.browseId ?? media?.id;
    if (!id || !String(query).trim()) return { sections: [], playbackQueue: [] };
    let entry = this.#playlistSearchCache.get(id);
    if (!entry || entry.expires < Date.now()) {
      if (this.#playlistSearchCache.size >= 20) this.#playlistSearchCache.clear();
      const promise = this.playlist(id);
      entry = { promise, expires: Infinity };
      this.#playlistSearchCache.set(id, entry);
      promise.then(() => { entry.expires = Date.now() + 60000; }, () => { if (this.#playlistSearchCache.get(id) === entry) this.#playlistSearchCache.delete(id); });
    }
    const playlist = await entry.promise;
    const key = searchKey(query);
    const items = playlist.items.filter((item) => searchKey([item.title, item.artist, item.album].filter(Boolean).join(' ')).includes(key));
    return { sections: [{ id: 'playlist-search', title: 'Matching songs', items }], playbackQueue: playlist.items };
  }

  async browseRelated(media, kind) {
    if (!['artist', 'album'].includes(kind)) throw new Error('Invalid destination');
    const artist = primaryMusicArtist(media?.artist);
    let name = kind === 'artist' ? artist : media?.album;
    const open = async (id, type) => {
      if (!id || !(type === 'artist' ? isArtistId(id) : isAlbumId(id))) return null;
      try {
        const result = await this.browse({ id, type });
        return Array.isArray(result.sections) && !result.reason ? result : null;
      } catch { return null; } // Stale catalog links should fall through to metadata lookup.
    };
    const linked = await open(kind === 'artist' ? media?.artistBrowseId : media?.albumBrowseId, kind);
    if (linked) return linked;
    if (kind === 'album') {
      let candidates = [];
      try {
        const songs = await this.search([musicTitle(media?.title, artist), artist].filter(Boolean).join(' '), { type: 'song' });
        candidates = songs.sections.flatMap((section) => section.items);
      } catch { /* The current-song endpoint can still supply its album. */ }
      const song = candidates.find((item) => item.videoId === (media?.videoId ?? media?.id)) ??
        candidates.find((item) => sameRecording(item, media) && (!media?.album || catalogKey(item.album) === catalogKey(media.album)));
      const matched = await open(song?.albumBrowseId, 'album');
      if (matched) return matched;
      name = name || song?.album;
      // Unlike a fuzzy search, Up next carries the album link for this exact video.
      if (/^[a-zA-Z0-9_-]{11}$/.test(media?.videoId ?? media?.id ?? '')) {
        try {
          const queue = await boundedMusicInfo(async () => (await this.#client()).music.getUpNext(media.videoId ?? media.id, false), { timeoutMs: 4000 });
          const current = Array.from(queue?.contents ?? []).find((item) => item.video_id === (media.videoId ?? media.id));
          const exact = await open(current?.album?.id, 'album');
          if (exact) return exact;
          name = current?.album?.name || name;
        } catch { /* Retain the useful search result when the exact-video lookup is unavailable. */ }
      }
    }
    if (!name) throw new Error(`No ${kind} information is available for this song.`);
    const response = await this.search(kind === 'album' ? [name, artist].filter(Boolean).join(' ') : name, { type: kind });
    const candidates = response.sections.flatMap((section) => section.items);
    const match = candidates.find((item) => catalogKey(item.title) === catalogKey(name) &&
      (kind === 'artist' || !artist || catalogKey(primaryMusicArtist(item.artist)) === catalogKey(artist)));
    if (!match) throw new Error(`Could not find an exact ${kind} match. Try the ${kind} Search tab.`);
    return this.browse(match);
  }

  async suggestions(query) {
    const client = await this.#client();
    const sections = await client.music.getSearchSuggestions(query);
    return Array.from(sections ?? []).flatMap((section) =>
      Array.from(section.contents ?? []).map((item) => item?.suggestion?.toString?.()).filter(Boolean),
    );
  }

  async home() {
    const client = await this.#client();
    const home = await client.music.getHomeFeed();
    return {
      filters: home.filters ?? [],
      sections: Array.from(home.sections ?? []).map(normalizeSection),
    };
  }

  async explore() {
    const client = await this.#client();
    const explore = await client.music.getExplore();
    return {
      topButtons: Array.from(explore.top_buttons ?? []).map((button) => ({
        title: button.title?.toString?.() ?? '',
        browseId: button.endpoint?.payload?.browseEndpoint?.browseId ?? null,
      })),
      sections: Array.from(explore.sections ?? []).map(normalizeSection),
    };
  }

  async library() {
    const oauth = this.#oauthLibraryService?.authStatus() ?? { status: 'not_configured' };

    if (oauth.status === 'configured') {
      try {
        return await this.#oauthLibraryService.library();
      } catch (error) {
        if (error.code === 'oauth_reauthorization_required') {
          return authRequiredSections(
            'oauth_reauthorization_required',
            'Google OAuth authorization expired. Run the OAuth login command again.',
          );
        }
        throw error;
      }
    }

    return authRequiredSections(
      oauth.status === 'misconfigured' ? 'oauth_misconfigured' : 'oauth_required',
      oauth.status === 'misconfigured'
        ? 'Google OAuth client credentials and saved authorization must both be configured.'
        : 'Run the Google OAuth login command to access your Library.',
    );
  }

  async browse(media, { paged = false, continuation = null } = {}) {
    const id = media?.playlistId ?? media?.browseId ?? media?.id;
    if (!id) {
      return emptyBrowseResult('not_browsable', 'This item cannot be opened.');
    }

    const client = await this.#client();
    if (isAlbumId(id)) {
      const album = await client.music.getAlbum(id);
      return {
        id,
        title: album.header?.title?.toString?.() ?? media?.title ?? 'Album',
        sections: albumSections(album, media, id),
      };
    }

    if (isPlaylistId(id)) {
      if (this.#oauthLibraryService?.authStatus().status === 'configured') {
        const playlist = paged
          ? await this.#oauthLibraryService.playlistPage(id, continuation)
          : await this.#oauthLibraryService.playlist(id);
        return {
          id: playlist.id,
          title: playlist.title,
          continuation: playlist.continuation ?? null,
          sections: [{ id: 'tracks', title: 'Tracks', items: playlist.items }],
        };
      }
      const playlist = await client.music.getPlaylist(id);
      return {
        id,
        title: playlist.header?.title?.toString?.() ?? media?.title ?? 'Playlist',
        sections: [
          {
            id: 'tracks',
            title: 'Tracks',
            items: (await fullPlaylistItems(playlist)).map((item) => ({ ...item, artworkUrl: item.artworkUrl ?? bestThumbnailUrl(playlist.header?.thumbnails ?? playlist.header?.thumbnail) ?? media.artworkUrl ?? null })),
          },
        ],
      };
    }

    if (isArtistId(id)) {
      const artist = await client.music.getArtist(id);
      return {
        id,
        title: artist.header?.title?.toString?.() ?? media?.title ?? 'Artist',
        sections: await artistSections(artist),
      };
    }

    if (String(id).startsWith('FEmusic')) {
      return await this.#browseMusicEndpoint(id, media);
    }

    return emptyBrowseResult(
      'not_browsable',
      'This item is not directly browsable yet. Try a song, album, playlist, or artist.',
    );
  }

  async playlist(playlistId) {
    if (this.#oauthLibraryService?.authStatus().status === 'configured') {
      return await this.#oauthLibraryService.playlist(playlistId);
    }
    const client = await this.#client();
    const playlist = await client.music.getPlaylist(playlistId);
    return {
      id: playlistId,
      title: playlist.header?.title?.toString?.() ?? playlistId,
      items: (await fullPlaylistItems(playlist)).map((item) => ({ ...item, artworkUrl: item.artworkUrl ?? bestThumbnailUrl(playlist.header?.thumbnails ?? playlist.header?.thumbnail) ?? media.artworkUrl ?? null })),
    };
  }

  async track(videoId) {
    const info = await this.#playbackInfo(videoId);
    return normalizeTrackInfo(info);
  }

  async mix(videoId) {
    const client = await this.#client();
    return await recommendedMix(client.music, videoId);
  }

  async related(videoId) {
    const client = await this.#client();
    const related = await client.music.getRelated(videoId);
    return {
      sections: Array.from(related?.contents ?? related ?? []).map(normalizeSection),
    };
  }

  async setRating(videoId, likeStatus) {
    if (this.#oauthLibraryService?.authStatus().status !== 'configured') {
      const error = new Error('Google OAuth login is required to update YouTube ratings.');
      error.code = 'oauth_required';
      error.status = 401;
      throw error;
    }
    return await this.#oauthLibraryService.setRating(videoId, likeStatus);
  }

  async resolveStream(media, options = {}) {
    const videoId = streamVideoId(media);
    if (!videoId) {
      throw notPlayable('This item has no videoId. Select a song or video item.');
    }

    const cacheKey = streamCacheKey(videoId, options);
    const cached = this.#cachedStream(cacheKey);
    if (cached) {
      return cached.value;
    }

    const inflight = this.#streamInflight.get(cacheKey);
    if (inflight) {
      return await inflight;
    }

    const promise = this.#resolveStreamUncached(videoId, options, cacheKey);
    this.#streamInflight.set(cacheKey, promise);
    try {
      return await promise;
    } finally {
      this.#streamInflight.delete(cacheKey);
    }
  }

  prewarmStream(media, options = {}) {
    const videoId = streamVideoId(media);
    if (!videoId) return false;

    const cacheKey = streamCacheKey(videoId, options);
    if (this.#cachedStream(cacheKey) || this.#streamInflight.has(cacheKey)) {
      return false;
    }

    this.resolveStream(media, options).catch((error) => {
      console.warn(`stream prewarm failed for ${videoId}: ${error?.message ?? error}`);
    });
    return true;
  }

  invalidateStream(videoId, options = {}) {
    if (!videoId) return false;
    const cacheKey = streamCacheKey(videoId, options);
    const deletedCache = this.#streamCache.delete(cacheKey);
    const deletedInflight = this.#streamInflight.delete(cacheKey);
    return deletedCache || deletedInflight;
  }

  async #resolveStreamUncached(videoId, options = {}, cacheKey = streamCacheKey(videoId, options)) {
    const info = await this.#playbackInfo(videoId, options);
    assertPlayable(info);

    const selected = await this.#chooseTvOSFormat(info, options);
    const [directUrl, adaptiveVideoUrl, adaptiveAudioUrl] = await Promise.all([
      this.#decipherFormat(selected.playback),
      selected.video ? this.#decipherFormat(selected.video) : null,
      selected.audio ? this.#decipherFormat(selected.audio) : null,
    ]);
    const presentedVideo = selected.video ?? selected.playback;
    const value = {
      videoId,
      directUrl,
      adaptiveVideoUrl,
      adaptiveAudioUrl,
      mimeType: presentedVideo.mime_type,
      contentLength: presentedVideo.content_length ?? null,
      audioBitrate: selected.audio ? audioBitrate(selected.audio)
        : selected.playback.has_video ? null : audioBitrate(selected.playback),
      audioCodec: String((selected.audio ?? selected.playback).mime_type ?? '').match(/codecs="([^"]+)"/)?.[1] ?? null,
      hasAudio: selected.audio ? true : selected.playback.has_audio,
      hasVideo: presentedVideo.has_video,
      quality: presentedVideo.quality_label
        ?? presentedVideo.quality
        ?? presentedVideo.audio_quality
        ?? null,
      expiresAt: new Date(Date.now() + 45 * 60 * 1000).toISOString(),
      media: normalizeTrackInfo(info),
    };

    this.#streamCache.set(cacheKey, {
      value,
      expiresAt: Date.now() + 40 * 60 * 1000,
    });
    return value;
  }

  #cachedStream(cacheKey) {
    const cached = this.#streamCache.get(cacheKey);
    if (!cached) return null;
    if (cached.expiresAt <= Date.now()) {
      this.#streamCache.delete(cacheKey);
      return null;
    }
    return cached;
  }

  async stream(videoId, options = {}) {
    const info = await this.#playbackInfo(videoId);
    assertPlayable(info);
    const downloadOptions = {
      type: options.preferVideo ? 'video+audio' : 'audio',
      quality: options.quality ?? 'best',
      format: 'mp4',
    };
    return await info.download(downloadOptions);
  }

  async #playbackInfo(videoId, { skipOAuth = false, preferVideo = true } = {}) {
    const info = await boundedMusicInfo(() => this.#resolvePlaybackInfo(videoId, { skipOAuth, preferVideo }), { timeoutMs: 20000 });
    if (!info) throw new Error('Playback lookup failed or timed out. Please try again.');
    return info;
  }

  async #resolvePlaybackInfo(videoId, { skipOAuth = false, preferVideo = true } = {}) {
    let fallbackInfo = null;
    let fallbackError = null;
    if (!skipOAuth) {
      const playbackClient = await this.#playbackClient();
      const cookieClient = await this.#cookieMusicClient(playbackClient);
      // Audio-only Music playback should not wait for a TV OAuth request that
      // often fails or returns lower-quality audio. Keep the full Music budget.
      let cookieAttempted = false;
      if (cookieClient && !preferVideo) {
        cookieAttempted = true;
        const info = await boundedMusicInfo(() => cookieClient.getBasicInfo(videoId, { client: 'YTMUSIC' }));
        if (isPlayable(info) && selectTvOSFormats(info, { preferVideo: false }).playback) return info;
        console.warn('Cookie Music playback unavailable; trying TV playback fallback.');
      }
      if (this.#oauthLibraryService?.authStatus().status === 'configured') {
        try {
          await this.#oauthLibraryService.authorizeSession(playbackClient);
          const info = await boundedMusicInfo(() => playbackClient.getBasicInfo(videoId, { client: 'TV' }), { timeoutMs: 8000 });
          if (isPlayable(info) && selectTvOSFormats(info, { preferVideo: false }).playback) {
            // Music web playback can reject TV OAuth tokens. Use the optional
            // browser-cookie session for Premium audio, without changing Library auth.
            return cookieClient && !cookieAttempted ? await upgradeMusicAudio(info, () => cookieClient
              .getBasicInfo(videoId, { client: 'YTMUSIC' })) : info;
          }
          console.warn(`OAuth TV player returned ${info?.playability_status?.status ?? 'unknown'} for ${videoId}`);
        } catch (error) {
          console.warn(`OAuth TV player failed for ${videoId}: ${error?.message ?? error}`);
        }
      }

      if (cookieClient && !cookieAttempted) {
        const info = await boundedMusicInfo(() => cookieClient.getBasicInfo(videoId, { client: 'YTMUSIC' }));
        if (isPlayable(info) && selectTvOSFormats(info, { preferVideo: false }).playback) return info;
        console.warn('Cookie Music playback unavailable; retaining existing playback fallback.');
      }

      try {
        const publicClient = await this.#client();
        const info = await boundedMusicInfo(() => publicClient.getBasicInfo(videoId, { client: 'YTMUSIC' }));
        if (isPlayable(info) && selectTvOSFormats(info, { preferVideo: false }).playback) {
          return info;
        }
        fallbackInfo = info;
        console.warn(`Public Music player returned ${info?.playability_status?.status ?? 'unavailable'} for ${videoId}, falling back to getBasicInfo`);
      } catch (error) {
        fallbackError = error;
        console.warn(`Public Music player failed for ${videoId}, falling back to getBasicInfo: ${error?.message ?? error}`);
      }
    }

    const client = await this.#client();
    for (const clientName of ['ANDROID', 'WEB', 'IOS']) {
      try {
        const info = await boundedMusicInfo(() => client.getBasicInfo(videoId, { client: clientName }), { timeoutMs: 8000 });
        if (isPlayable(info) && selectTvOSFormats(info, { preferVideo: false }).playback) {
          return info;
        }
        fallbackInfo = info;
      } catch (error) {
        fallbackError = error;
      }
    }

    if (fallbackInfo) {
      return fallbackInfo;
    }
    throw fallbackError ?? new Error(`Unable to retrieve playback info for ${videoId}`);
  }

  async #chooseTvOSFormat(info, options) {
    const preferVideo = options.preferVideo !== false;
    const quality = options.quality ?? 'best';
    const compatibleFormats = selectTvOSFormats(info, { preferVideo, quality });
    if (compatibleFormats.playback) {
      return compatibleFormats;
    }
    const attempts = preferVideo
      ? [
          { type: 'video+audio', quality, format: 'mp4' },
          { type: 'video+audio', quality: 'bestefficiency', format: 'mp4' },
          { type: 'audio', quality: 'best', format: 'mp4' },
          { type: 'audio', quality: 'best', format: 'any' },
        ]
      : [
          { type: 'audio', quality: 'best', format: 'mp4' },
          { type: 'audio', quality: 'best', format: 'any' },
          { type: 'video+audio', quality: 'bestefficiency', format: 'mp4' },
        ];

    let lastError;
    for (const attempt of attempts) {
      try {
        return {
          playback: info.chooseFormat(attempt),
          video: null,
          audio: null,
        };
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? new Error('No playable format found');
  }

  async #client() {
    if (!this.#clientPromise) {
      this.#clientPromise = this.#createClient({
        retrievePlayer: false,
      });
    }
    try { return await this.#clientPromise; }
    catch (error) { this.#clientPromise = null; throw error; }
  }

  async #playbackClient() {
    if (!this.#playbackClientPromise) {
      this.#playbackClientPromise = this.#createClient({
        retrievePlayer: true,
        clientName: 'TVHTML5',
      });
    }
    try { return await this.#playbackClientPromise; }
    catch (error) { this.#playbackClientPromise = null; throw error; }
  }

  async #cookieMusicClient(playbackClient) {
    if (!this.#cookieFile) return null;
    let cookie = '';
    try {
      cookie = cookieHeaderFromNetscape(await readFile(this.#cookieFile, 'utf8'));
    } catch (error) {
      if (error?.code !== 'ENOENT' && !this.#cookieWarning) {
        console.warn('Unable to load YouTube Music cookie file; using existing playback.');
        this.#cookieWarning = true;
      }
    }
    if (!cookie) {
      this.#cookieHeader = '';
      this.#cookieClientPromise = null;
      return null;
    }
    this.#cookieWarning = false;
    if (cookie !== this.#cookieHeader || !this.#cookieClientPromise) {
      this.#cookieHeader = cookie;
      this.#cookieClientPromise = this.#createClient({ retrievePlayer: false, clientName: 'WEB_REMIX', cookie });
    }
    try {
      const client = await this.#cookieClientPromise;
      // Reuse the already-loaded signature player so the optional lookup doesn't
      // add another player-script fetch or change stream deciphering.
      client.session.player = playbackClient.session.player;
      return client;
    } catch {
      this.#cookieClientPromise = null;
      console.warn('Unable to initialize cookie Music playback; using existing playback.');
      return null;
    }
  }

  async #decipherFormat(format) {
    const canUseDirectUrl = Boolean(format.url);
    const needsPlayer = Boolean(format.signature_cipher || format.cipher || format.url?.includes('&n='));
    if (!needsPlayer) {
      return await format.decipher();
    }

    try {
      const client = await this.#playbackClient();
      return await format.decipher(client.session.player);
    } catch (error) {
      if (canUseDirectUrl) {
        console.warn(`player decipher failed, using direct format URL: ${error?.message ?? error}`);
        return await format.decipher();
      }
      throw error;
    }
  }

  async #createClient({ retrievePlayer, clientName = null, cookie = null }) {
    const config = this.#configStore.get();
    const session = this.#sessionStore.get();

    const client = await this.#clientFactory({
      cache: new UniversalCache(false),
      po_token: session.poToken || config.youtube.poToken || undefined,
      visitor_data: session.visitorData || config.youtube.visitorData || undefined,
      account_index: config.youtube.accountIndex ?? 0,
      user_agent: config.youtube.userAgent,
      generate_session_locally: true,
      retrieve_player: retrievePlayer,
      fetch: this.#fetch,
      ...(cookie ? { cookie, retrieve_innertube_config: false } : {}),
      ...(clientName ? { client_type: clientName } : {}),
    });
    return client;
  }

  async #browseMusicEndpoint(id, media) {
    const client = await this.#client();
    try {
      const response = await client.actions.execute('/browse', {
        browseId: id,
        client: 'YTMUSIC',
        skip_auth_check: true,
      });
      const parsed = Parser.parseResponse(response.data);
      const sections = sectionsFromParsedResponse(parsed);
      return {
        id,
        title: media?.title ?? id,
        sections,
      };
    } catch (error) {
      if (isAuthRequiredError(error)) {
        return authRequiredSections(
          'oauth_required',
          'This library section requires Google OAuth login.',
        );
      }
      throw error;
    }
  }
}

const authRequiredSections = (reason = 'auth_required', message = 'Authentication is required.') => ({
  authRequired: true,
  reason,
  message,
  filters: [],
  sortOptions: [],
  sections: [],
});

const emptyBrowseResult = (reason, message) => ({
  reason,
  message,
  sections: [],
});

const assertPlayable = (info) => {
  if (isPlayable(info)) return;

  const status = info?.playability_status;
  const reason =
    status.reason ??
    status.error_screen?.reason?.text ??
    status.error_screen?.subreason?.text ??
    status.status;
  throw notPlayable(`Video is not playable: ${reason}`);
};

const notPlayable = (message) => {
  const error = new Error(message);
  error.status = 422;
  error.code = 'not_playable';
  return error;
};

const isPlayable = (info) => {
  const status = info?.playability_status;
  return Boolean(info) && (!status || status.status === 'OK');
};

const streamVideoId = (media) => media?.videoId ?? media?.id ?? null;

const streamCacheKey = (videoId, options = {}) =>
  `${videoId}:${options.preferVideo ?? true}:${options.quality ?? 'best'}:${options.skipOAuth === true}`;

export const selectTvOSFormats = (info, { preferVideo, quality = 'best' }) => {
  const streamingData = info?.streaming_data;
  const formats = [
    ...Array.from(streamingData?.formats ?? []),
    ...Array.from(streamingData?.adaptive_formats ?? []),
  ];

  const audioFormats = compatibleAudioFormats(formats);

  if (!preferVideo) {
    return { playback: audioFormats[0] ?? null, video: null, audio: null };
  }

  const progressiveFormats = formats
    .filter((format) => {
      const mimeType = String(format?.mime_type ?? '').toLowerCase();
      return format?.has_audio === true &&
        format?.has_video === true &&
        mimeType.startsWith('video/mp4') &&
        mimeType.includes('avc1') &&
        mimeType.includes('mp4a');
    })
    .sort(compareVideoFormats);

  const adaptiveVideoFormats = formats
    .filter((format) => {
      const mimeType = String(format?.mime_type ?? '').toLowerCase();
      return format?.has_video === true &&
        format?.has_audio !== true &&
        mimeType.startsWith('video/mp4') &&
        mimeType.includes('avc1');
    })
    .sort(compareVideoFormats);

  const progressive = formatForQuality(progressiveFormats, quality);
  const adaptiveVideo = formatForQuality(adaptiveVideoFormats, quality);
  // Video resolution and audio quality are separate choices. Even a low-resolution
  // video can use the best AAC track instead of its bundled lower-quality audio.
  const bestVideo = adaptiveVideo && (adaptiveVideo.height ?? 0) >= (progressive?.height ?? 0)
    ? adaptiveVideo : progressive;
  const shouldUseAdaptive = Boolean(bestVideo && audioFormats[0]);

  return {
    playback: progressive ?? audioFormats[0] ?? null,
    video: shouldUseAdaptive ? bestVideo : null,
    audio: shouldUseAdaptive ? audioFormats[0] : null,
  };
};

const compareVideoFormats = (left, right) =>
  ((right.height ?? 0) - (left.height ?? 0)) ||
  ((right.bitrate ?? 0) - (left.bitrate ?? 0));

const formatForQuality = (formats, quality) => {
  if (formats.length === 0) return null;
  const maximumHeight = qualityMaximumHeight(quality);
  return formats.find((format) => (format.height ?? 0) <= maximumHeight)
    ?? (maximumHeight === Number.POSITIVE_INFINITY ? formats[0] : null);
};

const qualityMaximumHeight = (quality) => {
  if (String(quality).toLowerCase() === 'bestefficiency') return 360;
  const match = String(quality).match(/^(\d+)p$/i);
  return match ? Number(match[1]) : Number.POSITIVE_INFINITY;
};

const isAuthRequiredError = (error) =>
  String(error?.message ?? error).toLowerCase().includes('signed in');

const isAlbumId = (id) => String(id).startsWith('MPR');
const isArtistId = (id) =>
  String(id).startsWith('UC') || String(id).startsWith('FEmusic_library_privately_owned_artist');
const isPlaylistId = (id) => {
  const value = String(id);
  return value.startsWith('VL') || value.startsWith('PL') || value.startsWith('RD');
};

const sectionsFromParsedResponse = (parsed) => {
  const shelves = parsed.contents_memo?.getType(
    YTNodes.Grid,
    YTNodes.MusicShelf,
    YTNodes.MusicCarouselShelf,
  ) ?? [];
  return shelves.map(normalizeSection).filter((section) => section.items.length > 0);
};

export const libraryFromParsedResponse = (parsed) => {
  const memo = parsed.contents_memo;
  const chipCloud = memo?.getType(YTNodes.ChipCloud)?.[0];
  const sortButton = memo?.getType(YTNodes.MusicSortFilterButton)?.[0];

  return {
    filters: Array.from(chipCloud?.chips ?? [])
      .map((chip) => chip?.text?.toString?.() ?? String(chip?.text ?? ''))
      .filter(Boolean),
    sortOptions: Array.from(sortButton?.menu?.options ?? [])
      .map((option) => option?.title?.toString?.() ?? String(option?.title ?? ''))
      .filter(Boolean),
    sections: sectionsFromParsedResponse(parsed),
  };
};

const searchKey = (value) => String(value ?? '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
export const artistSections = async (artist) => {
  const sections = Array.from(artist.sections ?? []).map(normalizeSection);
  // The artist page exposes only a preview; follow its All songs endpoint.
  try {
    const all = await artist.getAllSongs();
    const expanded = all ? normalizeSection({ title: 'Top songs', contents: all.contents }) : null;
    if (expanded?.items.length) {
      const index = sections.findIndex((section) => /top songs/i.test(section.title));
      if (index >= 0) sections[index] = expanded;
      else sections.unshift(expanded);
    }
  } catch { /* Keep the usable artist page when its All songs endpoint is absent. */ }
  return sections;
};

// Follow public playlist pages as well as OAuth Library pages for full-playlist search.
export const fullPlaylistItems = async (playlist, limit = 5000) => {
  const items = [];
  let page = playlist;
  for (let pages = 0; page && pages < 100 && items.length < limit; pages++) {
    items.push(...Array.from(page.items ?? []).map((item) => normalizeMediaNode(item)).filter(Boolean).slice(0, limit - items.length));
    if (!page.has_continuation || items.length >= limit) break;
    page = await page.getContinuation();
  }
  return items;
};

export const recommendedMix = async (music, videoId) => {
  const panel = await music.getUpNext(videoId, true);
  const seen = new Set([videoId]);
  const items = Array.from(panel?.contents ?? []).flatMap((node) => {
    if (!node?.video_id || seen.has(node.video_id)) return [];
    seen.add(node.video_id);
    const media = normalizeMediaNode({ ...node, id: node.video_id, item_type: 'song',
      artists: node.artists?.length ? node.artists : [{ name: String(node.author ?? '') }] });
    return media ? [media] : [];
  });
  return { sections: [{ id: 'song-mix', title: 'Song mix', items }] };
};

const audioBitrate = (format) => Number(format?.average_bitrate ?? format?.bitrate ?? format?.audio_bitrate ?? 0) || 0;
const compatibleAudioFormats = (formats) => Array.from(formats ?? []).filter((format) => {
  const mime = String(format?.mime_type ?? '').toLowerCase();
  return format?.has_audio === true && format?.has_video !== true && mime.startsWith('audio/mp4') && mime.includes('mp4a');
}).sort((left, right) => audioBitrate(right) - audioBitrate(left));

export const cookieHeaderFromNetscape = (text, { now = Date.now() } = {}) => {
  if (typeof text !== 'string' || text.length > 131072) throw new Error('Invalid cookie file');
  const cookies = new Map();
  for (let line of text.split(/\r?\n/)) {
    if (line.startsWith('#HttpOnly_')) line = line.slice('#HttpOnly_'.length);
    if (!line || line.startsWith('#')) continue;
    const fields = line.split('\t');
    if (fields.length !== 7) continue;
    const [domain, , path, , expires, name, value] = fields;
    if (!['.youtube.com', 'youtube.com'].includes(domain.toLowerCase()) || path !== '/') continue;
    const expiry = Number(expires);
    if (!Number.isFinite(expiry) || expiry < 0 || (expiry && expiry * 1000 <= now)) continue;
    if (!/^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(name) || !/^[\x21-\x3A\x3C-\x7E]+$/.test(value)) continue;
    cookies.set(name, value);
  }
  // youtubei.js signs cookie requests with SAPISID. Don't send unrelated or
  // incomplete exports as though they provided an authenticated Music session.
  if (!cookies.has('SAPISID')) return '';
  return [...cookies].map(([name, value]) => `${name}=${value}`).join('; ');
};

export const boundedMusicInfo = async (fetchMusicInfo, { timeoutMs = 5000 } = {}) => {
  const controller = new AbortController();
  const parent = playbackRequestScope.getStore();
  const signal = parent ? AbortSignal.any([parent, controller.signal]) : controller.signal;
  let deadline, onAbort;
  try {
    if (signal.aborted) return null;
    return await Promise.race([
      playbackRequestScope.run(signal, () => Promise.resolve().then(() => fetchMusicInfo(signal))),
      new Promise((resolve) => {
        onAbort = () => resolve(null);
        signal.addEventListener('abort', onAbort, { once: true });
        deadline = setTimeout(() => controller.abort(), timeoutMs);
      }),
    ]);
  } catch { return null; }
  finally {
    clearTimeout(deadline);
    if (onAbort) signal.removeEventListener('abort', onAbort);
    controller.abort();
  }
};

export const upgradeMusicAudio = async (info, fetchMusicInfo, { timeoutMs = 5000 } = {}) => {
  const data = info?.streaming_data;
  if (!data) return info;
  const current = compatibleAudioFormats([...(data.formats ?? []), ...(data.adaptive_formats ?? [])])[0];
  if (audioBitrate(current) >= 256000) return info;
  const musicInfo = await boundedMusicInfo(fetchMusicInfo, { timeoutMs });
  if (!isPlayable(musicInfo)) return info;
  const musicData = musicInfo?.streaming_data;
  const audio = compatibleAudioFormats([...(musicData?.formats ?? []), ...(musicData?.adaptive_formats ?? [])])[0];
  if (audio && audioBitrate(audio) > audioBitrate(current)) {
    // Keep TV video formats, metadata and methods; only add the improved audio track.
    data.adaptive_formats = [...(data.adaptive_formats ?? []), audio];
  }
  return info;
};

const studioVideoTitle = (title) => String(title ?? '')
  .replace(/\s*[([](?:live\b|performed\b|performance\b|concert\b)[^)\]]*[)\]]/gi, '')
  .replace(/\s+[-–—]\s+(?:live\b|performed\b|performance\b|concert\b).*$/i, '').trim();

const primaryMusicArtist = (value) => String(value ?? '').replace(/\s*[-–—]\s*Topic(?=,|$)/gi, '').replace(/VEVO$/i, '').split(/,|;| feat\.? | featuring | ft\.? /i)[0].trim();
const musicTitle = (value, artist) => {
  const title = String(value ?? '').replace(/\s*[([][^)\]]*(?:official|video|audio|lyrics?|visualizer|4k|hd)[^)\]]*[)\]]/gi, '').trim();
  const parts = title.split(/\s+[-–—]\s+/);
  return parts.length > 1 && catalogKey(parts[0]) === catalogKey(artist) ? parts.slice(1).join(' - ') : title;
};
const catalogKey = (value) => searchKey(value).replace(/&/g, ' and ').replace(/[^\p{L}\p{N}]+/gu, ' ').trim().replace(/\s+/g, ' ');
export const sameRecording = (candidate, media) => Boolean(candidate.title && candidate.artist &&
  catalogKey(musicTitle(candidate.title, primaryMusicArtist(candidate.artist))) === catalogKey(musicTitle(media?.title, primaryMusicArtist(media?.artist))) &&
  catalogKey(primaryMusicArtist(candidate.artist)) === catalogKey(primaryMusicArtist(media?.artist)) &&
  (!candidate.durationMs || !media?.durationMs || Math.abs(candidate.durationMs - media.durationMs) <= 12000));

export const albumSections = (album, media, id) => {
  const header = album.header;
  const author = header?.author ?? header?.strapline_text_one?.runs?.find((run) => run.endpoint?.payload?.browseId?.startsWith('UC'));
  const fallback = {
    itemType: 'song', album: header?.title?.toString?.() ?? media.title,
    albumBrowseId: id, artist: author?.name ?? author?.text ?? media.artist,
    artistBrowseId: author?.channel_id ?? author?.endpoint?.payload?.browseId ?? media.artistBrowseId,
    artworkUrl: bestThumbnailUrl(header?.thumbnails ?? header?.thumbnail) ?? media.artworkUrl,
  };
  return [
    { id: 'tracks', title: 'Tracks', items: Array.from(album.contents ?? []).map((item) => normalizeMediaNode(item, fallback)).filter(Boolean) },
    ...Array.from(album.sections ?? []).map(normalizeSection),
  ];
};
