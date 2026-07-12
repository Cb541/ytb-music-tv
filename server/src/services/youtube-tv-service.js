import { Innertube, UniversalCache } from 'youtubei.js';

const TV_CLIENT = 'TV';
const TV_SESSION_CLIENT = 'TVHTML5';
const YOUTUBE_WRITE_SCOPE = 'https://www.googleapis.com/auth/youtube';

export class YouTubeTvService {
  #oauth;
  #clientFactory;
  #clientPromise;
  #maxItems;
  #fetch;

  constructor({
    oauth,
    clientFactory = createTvClient,
    maxItems = 5000,
    fetchFunction = globalThis.fetch,
  }) {
    this.#oauth = oauth;
    this.#clientFactory = clientFactory;
    this.#maxItems = maxItems;
    this.#fetch = fetchFunction;
  }

  authStatus() {
    return this.#oauth.status();
  }

  async authorizeSession(client, { forceRefresh = false } = {}) {
    await this.#authorize(client, forceRefresh);
  }

  async library() {
    const responses = await Promise.all(MUSIC_LIBRARY_TABS.map(async (tab) => {
      const response = await this.#browse(tab.browseId);
      const grid = selectedTabGrid(response, tab.browseId);
      return {
        ...tab,
        items: await this.#collectContinuationItems(grid),
      };
    }));
    const sections = responses
      .map(({ id, title, items, likeStatus }) => ({
        id,
        title,
        items: items
          .map((entry) => normalizeTile(entry?.tileRenderer, { likeStatus }))
          .filter(Boolean),
      }))
      .filter((section) => section.items.length > 0);

    return {
      provider: 'youtube-music-tv-oauth',
      filters: [],
      sortOptions: [],
      sections,
    };
  }

  async playlist(playlistId) {
    const browseId = playlistBrowseId(playlistId);
    const response = await this.#browse(browseId);
    const metadata = firstRenderer(response, 'entityMetadataRenderer');
    const list = firstRenderer(response, 'playlistVideoListRenderer');
    const items = await this.#collectContinuationItems(list);

    return {
      id: browseId,
      title: textOf(metadata?.title) || browseId,
      items: items
        .map((item) => normalizeTile(item?.tileRenderer, {
          likeStatus: browseId === 'VLLL' || browseId === 'VLLM' ? 'LIKE' : 'INDIFFERENT',
        }))
        .filter(Boolean),
    };
  }

  async setRating(videoId, likeStatus) {
    const scope = this.#oauth.status().scope;
    if (scope && !String(scope).split(/\s+/).includes(YOUTUBE_WRITE_SCOPE)) {
      const error = new Error(
        'Google OAuth authorization is read-only. Run the OAuth login command again to enable ratings.',
      );
      error.code = 'oauth_write_scope_required';
      error.status = 403;
      throw error;
    }
    return await this.#executeRating(videoId, likeStatus, true);
  }

  async #executeRating(videoId, likeStatus, retry) {
    const client = await this.#client();
    await this.#authorize(client, false);
    const endpoint = {
      LIKE: 'like/like',
      DISLIKE: 'like/dislike',
      INDIFFERENT: 'like/removelike',
    }[likeStatus];
    if (!endpoint) {
      const error = new Error(`Unsupported like status: ${likeStatus}`);
      error.code = 'invalid_like_status';
      error.status = 400;
      throw error;
    }

    try {
      await client.session.http.fetch(endpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ target: { videoId }, client: TV_CLIENT }),
      });
    } catch (cause) {
      const status = httpStatusFromError(cause);
      if (status === 401 && retry) {
        await this.#authorize(client, true);
        return await this.#executeRating(videoId, likeStatus, false);
      }
      const error = new Error(String(cause?.message ?? cause));
      error.code = status === 401 ? 'oauth_reauthorization_required' : 'youtube_rating_failed';
      error.status = status || 502;
      throw error;
    }
    return { videoId, likeStatus };
  }

  async #browse(browseId, retry = true) {
    return await this.#execute({ browseId }, retry);
  }

  async #browseContinuation(token, retry = true) {
    return await this.#execute({ token }, retry);
  }

  async #collectContinuationItems(renderer) {
    const items = contentItems(renderer);
    let continuation = continuationToken(renderer);
    const seenContinuations = new Set();

    while (continuation && !seenContinuations.has(continuation) && items.length < this.#maxItems) {
      seenContinuations.add(continuation);
      const next = await this.#browseContinuation(continuation);
      const continued = firstContinuationCollection(next);
      if (!continued) break;
      items.push(...contentItems(continued));
      continuation = continuationToken(continued);
    }
    return items.slice(0, this.#maxItems);
  }

  async #execute(payload, retry) {
    const client = await this.#client();
    await this.#authorize(client, false);
    const response = await client.actions.execute('/browse', {
      ...payload,
      client: TV_CLIENT,
      skip_auth_check: true,
    });

    if (response.status_code === 401 && retry) {
      await this.#authorize(client, true);
      return await this.#execute(payload, false);
    }
    if (!response.success) {
      const message = response.data?.error?.message ?? `YouTube TV browse failed with HTTP ${response.status_code}.`;
      const error = new Error(message);
      error.code = response.status_code === 401 ? 'oauth_reauthorization_required' : 'youtube_tv_request_failed';
      error.status = response.status_code;
      throw error;
    }
    return response.data;
  }

  async #authorize(client, forceRefresh) {
    const accessToken = await this.#oauth.accessToken({ forceRefresh });
    const expiresAt = this.#oauth.status().expiresAt;
    client.session.oauth.setTokens({
      access_token: accessToken,
      // Refreshing and persistence are owned by GoogleOAuthClient. This placeholder
      // only satisfies youtubei.js token validation and is never sent to Google.
      refresh_token: 'managed-by-ytb-music-tv',
      expiry_date: validFutureDate(expiresAt),
    });
    client.session.logged_in = true;
  }

  async #client() {
    if (!this.#clientPromise) {
      this.#clientPromise = this.#clientFactory({ fetchFunction: this.#fetch });
    }
    return await this.#clientPromise;
  }
}

const createTvClient = async ({ fetchFunction = globalThis.fetch } = {}) => await Innertube.create({
  cache: new UniversalCache(false),
  generate_session_locally: true,
  retrieve_player: false,
  client_name: TV_SESSION_CLIENT,
  fetch: fetchFunction,
});

const httpStatusFromError = (error) => {
  const status = Number(error?.status ?? error?.statusCode);
  if (Number.isInteger(status) && status >= 100 && status <= 599) return status;
  const match = String(error?.message ?? error).match(/status(?: code)?\s+(\d{3})/i);
  return match ? Number(match[1]) : null;
};

export const normalizeTvTile = (tile, options = {}) => normalizeTile(tile, options);

const normalizeTile = (tile, { likeStatus = 'INDIFFERENT' } = {}) => {
  if (!tile) return null;
  const metadata = tile.metadata?.tileMetadataRenderer;
  const title = textOf(metadata?.title) || textOf(tile.onLongPressCommand?.showMenuCommand?.title);
  const watch = tile.onSelectCommand?.watchEndpoint;
  const browse = tile.onSelectCommand?.browseEndpoint;
  const videoId = watch?.videoId ?? (tile.contentType === 'TILE_CONTENT_TYPE_VIDEO' ? tile.contentId : null);
  const endpointPlaylistId = videoId ? null : watch?.playlistId ?? null;
  const browseId = browse?.browseId ?? (endpointPlaylistId ? `VL${endpointPlaylistId}` : null);
  if (!title || (!videoId && !browseId)) return null;

  const isPlaylist = !videoId && (
    Boolean(endpointPlaylistId) ||
    tile.contentType === 'TILE_CONTENT_TYPE_PLAYLIST' ||
    String(browseId).startsWith('VL')
  );
  const isChannel = tile.contentType === 'TILE_CONTENT_TYPE_CHANNEL' && !isPlaylist;
  const thumbnail = tile.header?.tileHeaderRenderer?.thumbnail;
  const durationText = tile.header?.tileHeaderRenderer?.thumbnailOverlays
    ?.find((entry) => entry.thumbnailOverlayTimeStatusRenderer)
    ?.thumbnailOverlayTimeStatusRenderer?.text;
  const artist = lineText(metadata?.lines?.[0]);
  const id = videoId ?? browseId ?? tile.contentId;

  return {
    id,
    videoId: videoId ?? null,
    browseId,
    playlistId: isPlaylist ? browseId : null,
    type: isPlaylist ? 'playlist' : isChannel ? 'artist' : 'song',
    title,
    artist,
    album: null,
    durationMs: parseDuration(textOf(durationText)),
    artworkUrl: bestThumbnailUrl(thumbnail),
    streamUrl: null,
    sourceUrl: videoId
      ? `https://music.youtube.com/watch?v=${encodeURIComponent(videoId)}`
      : isPlaylist
        ? `https://music.youtube.com/playlist?list=${encodeURIComponent(String(browseId).replace(/^VL/, ''))}`
        : browseId
          ? `https://www.youtube.com/channel/${encodeURIComponent(browseId)}`
          : null,
    likeStatus,
    tags: artist ? [artist] : [],
  };
};

const collectByRenderer = (root, rendererName) => {
  const values = [];
  visit(root, (key, value) => {
    if (key === rendererName) values.push(value);
  });
  return values;
};

const firstRenderer = (root, rendererName) => collectByRenderer(root, rendererName)[0] ?? null;

const selectedTabGrid = (response, browseId) => {
  const tabs = collectByRenderer(response, 'tabRenderer');
  const selected = tabs.find((tab) => tab.selected) ??
    tabs.find((tab) => tab.endpoint?.browseEndpoint?.browseId === browseId);
  return firstRenderer(selected?.content, 'gridRenderer') ?? firstRenderer(response, 'gridRenderer');
};

const visit = (value, callback) => {
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    callback(key, child);
    visit(child, callback);
  }
};

const firstContinuationCollection = (response) => {
  const continuationContents = response?.continuationContents;
  if (continuationContents) {
    const collection = Object.values(continuationContents).find((value) =>
      Array.isArray(value?.contents) || Array.isArray(value?.items));
    if (collection) return collection;
  }
  const append = firstRenderer(response, 'appendContinuationItemsAction');
  return Array.isArray(append?.continuationItems)
    ? { items: append.continuationItems }
    : null;
};

const rendererItems = (renderer) => Array.from(renderer?.items ?? renderer?.contents ?? []);

const contentItems = (renderer) => rendererItems(renderer)
  .filter((item) => !item?.continuationItemRenderer);

const continuationToken = (renderer) =>
  renderer?.continuations?.[0]?.nextContinuationData?.continuation
  ?? rendererItems(renderer)
    .map((item) => item?.continuationItemRenderer?.continuationEndpoint?.continuationCommand?.token)
    .find(Boolean)
  ?? null;

const playlistBrowseId = (playlistId) => {
  const id = String(playlistId ?? '');
  if (id.startsWith('VL')) return id;
  return `VL${id}`;
};

const lineText = (line) => Array.from(line?.lineRenderer?.items ?? [])
  .map((item) => textOf(item?.lineItemRenderer?.text))
  .filter((value) => value && value !== '•')
  .join(' ');

const textOf = (value) => {
  if (!value) return '';
  if (typeof value === 'string') return value;
  if (typeof value.simpleText === 'string') return value.simpleText;
  if (Array.isArray(value.runs)) return value.runs.map((run) => run?.text ?? '').join('');
  return '';
};

const bestThumbnailUrl = (thumbnail) => Array.from(thumbnail?.thumbnails ?? [])
  .sort((left, right) => ((right.width ?? 0) * (right.height ?? 0)) -
    ((left.width ?? 0) * (left.height ?? 0)))[0]?.url ?? null;

const parseDuration = (value) => {
  const parts = String(value).split(':').map(Number);
  if (parts.length < 2 || parts.some((part) => !Number.isFinite(part))) return 0;
  return parts.reduce((total, part) => total * 60 + part, 0) * 1000;
};

const validFutureDate = (value) => {
  const timestamp = Date.parse(value ?? '');
  return Number.isFinite(timestamp) && timestamp > Date.now() + 30_000
    ? new Date(timestamp).toISOString()
    : new Date(Date.now() + 5 * 60_000).toISOString();
};

const MUSIC_LIBRARY_TABS = [
  {
    id: 'music-listen-again',
    title: 'Listen again',
    browseId: 'FEmusic_last_played',
    likeStatus: 'INDIFFERENT',
  },
  {
    id: 'music-playlists',
    title: 'Playlists',
    browseId: 'FEmusic_liked_playlists',
    likeStatus: 'INDIFFERENT',
  },
  {
    id: 'music-albums',
    title: 'Albums',
    browseId: 'FEmusic_liked_albums',
    likeStatus: 'INDIFFERENT',
  },
  {
    id: 'music-songs',
    title: 'Songs',
    browseId: 'FEmusic_liked_videos',
    likeStatus: 'LIKE',
  },
  {
    id: 'music-artists',
    title: 'Artists',
    browseId: 'FEmusic_library_corpus_artists',
    likeStatus: 'INDIFFERENT',
  },
];
