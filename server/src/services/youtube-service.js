import { Innertube, Parser, Platform, UniversalCache, YTNodes } from 'youtubei.js';

import {
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
  #streamCache = new Map();
  #streamInflight = new Map();
  #playlistSearchCache = new Map();

  constructor({ configStore, sessionStore, oauthLibraryService = null, fetchFunction = globalThis.fetch }) {
    this.#configStore = configStore;
    this.#sessionStore = sessionStore;
    this.#oauthLibraryService = oauthLibraryService;
    this.#fetch = fetchFunction;
  }

  authStatus() {
    const session = this.#sessionStore.get();
    const oauth = this.#oauthLibraryService?.authStatus() ?? { status: 'not_configured' };
    return {
      mode: 'google-device-oauth',
      status: oauth.status,
      hasCookie: false,
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
    let name = kind === 'artist' ? String(media?.artist ?? '').replace(/\s*-\s*Topic$/i, '').split(',')[0].trim() : media?.album;
    if (kind === 'album' && !name) {
      const songs = await this.search([media?.title, media?.artist].filter(Boolean).join(' '), { type: 'song' });
      const candidates = songs.sections.flatMap((section) => section.items);
      const song = candidates.find((item) => item.videoId === (media?.videoId ?? media?.id));
      if (song?.albumBrowseId) return this.browse({ id: song.albumBrowseId, type: 'album' });
      name = song?.album;
    }
    if (!name) throw new Error(`No ${kind} information is available for this song.`);
    const response = await this.search(name, { type: kind });
    const candidates = response.sections.flatMap((section) => section.items);
    const match = candidates.find((item) => searchKey(item.title) === searchKey(name) &&
      (kind === 'artist' || !media.artist || searchKey(item.artist).includes(searchKey(String(media.artist).split(',')[0]))));
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
        sections: [
          {
            id: 'tracks',
            title: 'Tracks',
            items: Array.from(album.contents ?? []).map((item) => normalizeMediaNode(item)).filter(Boolean),
          },
          ...Array.from(album.sections ?? []).map(normalizeSection),
        ],
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
            items: await fullPlaylistItems(playlist),
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
      items: await fullPlaylistItems(playlist),
    };
  }

  async track(videoId) {
    const info = await this.#playbackInfo(videoId);
    return normalizeTrackInfo(info);
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

  async #playbackInfo(videoId, { skipOAuth = false } = {}) {
    let fallbackInfo = null;
    let fallbackError = null;
    if (!skipOAuth) {
      const playbackClient = await this.#playbackClient();
      if (this.#oauthLibraryService?.authStatus().status === 'configured') {
        try {
          await this.#oauthLibraryService.authorizeSession(playbackClient);
          const info = await playbackClient.getBasicInfo(videoId, { client: 'TV' });
          if (isPlayable(info)) {
            return info;
          }
          console.warn(`OAuth TV player returned ${info?.playability_status?.status ?? 'unknown'} for ${videoId}`);
        } catch (error) {
          console.warn(`OAuth TV player failed for ${videoId}: ${error?.message ?? error}`);
        }
      }

      try {
        const info = await playbackClient.music.getInfo(videoId);
        if (isPlayable(info)) {
          return info;
        }
        fallbackInfo = info;
        console.warn(`music.getInfo returned ${info?.playability_status?.status ?? 'unknown'} for ${videoId}, falling back to getBasicInfo`);
      } catch (error) {
        fallbackError = error;
        console.warn(`music.getInfo failed for ${videoId}, falling back to getBasicInfo: ${error?.message ?? error}`);
      }
    }

    const client = await this.#client();
    for (const clientName of ['ANDROID', 'WEB', 'IOS']) {
      try {
        const info = await client.getBasicInfo(videoId, { client: clientName });
        if (isPlayable(info)) {
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
    return await this.#clientPromise;
  }

  async #playbackClient() {
    if (!this.#playbackClientPromise) {
      this.#playbackClientPromise = this.#createClient({
        retrievePlayer: true,
        clientName: 'TVHTML5',
      });
    }
    return await this.#playbackClientPromise;
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

  async #createClient({ retrievePlayer, clientName = null }) {
    const config = this.#configStore.get();
    const session = this.#sessionStore.get();

    const client = await Innertube.create({
      cache: new UniversalCache(false),
      po_token: session.poToken || config.youtube.poToken || undefined,
      visitor_data: session.visitorData || config.youtube.visitorData || undefined,
      account_index: config.youtube.accountIndex ?? 0,
      user_agent: config.youtube.userAgent,
      generate_session_locally: true,
      retrieve_player: retrievePlayer,
      fetch: this.#fetch,
      ...(clientName ? { client_name: clientName } : {}),
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
  return !status || status.status === 'OK';
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

  const audioFormats = formats
    .filter((format) => {
      const mimeType = String(format?.mime_type ?? '').toLowerCase();
      return format?.has_audio === true &&
        format?.has_video !== true &&
        mimeType.startsWith('audio/mp4') &&
        mimeType.includes('mp4a');
    })
    .sort((left, right) => (right.bitrate ?? 0) - (left.bitrate ?? 0));

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
  const shouldUseAdaptive = Boolean(
    adaptiveVideo &&
    audioFormats[0] &&
    (adaptiveVideo.height ?? 0) > (progressive?.height ?? 0),
  );

  return {
    playback: progressive ?? audioFormats[0] ?? null,
    video: shouldUseAdaptive ? adaptiveVideo : null,
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
