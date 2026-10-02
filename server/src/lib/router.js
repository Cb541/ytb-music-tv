import { isBlockedUrl, proxyUrl } from '../features/adblock.js';
import { publicStreamUrl, streamResolvedMedia } from '../features/stream.js';
import { clientForRequest, issueClientToken } from './security.js';
import {
  json,
  methodNotAllowed,
  notFound,
  parseRequestUrl,
  readJson,
} from './http.js';
import { normalizeProxyConfig, proxyConfigPatch, publicProxyConfig } from './proxy-fetch.js';

export const createApiRouter = ({
  configStore,
  youtubeService,
  serverName = process.env.YTB_MUSIC_TV_SERVER_NAME ?? 'YTB Music TV',
  fetchFunction = globalThis.fetch,
}) => {
  return async (req, res) => {
    const url = parseRequestUrl(req);
    const pathname = decodeURIComponent(url.pathname);
    const baseUrl = `${url.protocol}//${url.host}`;

    if (req.method === 'OPTIONS') {
      res.writeHead(204, corsHeaders());
      res.end();
      return;
    }

    if (pathname === '/api/health') {
      if (req.method !== 'GET') return methodNotAllowed(res);
      const config = configStore.get();
      const client = clientForRequest(configStore, req);
      const authStatus = youtubeService.authStatus();
      return json(res, 200, {
        ok: true,
        service: 'ytb-music-tv-server',
        version: '0.1.0',
        serverId: config.security.serverId,
        serverName,
        associated: Boolean(client),
        client: client ? { id: client.id, name: client.name } : null,
        authenticated: authStatus.status === 'configured',
      }, corsHeaders());
    }

    if (pathname === '/api/config') {
      if (req.method === 'GET') {
        return json(res, 200, publicConfig(configStore.get()), corsHeaders());
      }
      if (req.method === 'PATCH') {
        const body = await readJson(req);
        const currentConfig = configStore.get();
        if (body.network && !clientForRequest(configStore, req)) {
          return json(res, 403, { error: 'pairing_required' }, corsHeaders());
        }
        let patch;
        try {
          patch = publicConfigPatch(body);
          if (patch.network?.proxy) {
            normalizeProxyConfig({
              ...(currentConfig.network?.proxy ?? {}),
              ...patch.network.proxy,
            });
          }
        } catch (error) {
          return json(res, error.status ?? 400, {
            error: error.code ?? 'invalid_config',
            message: String(error?.message ?? error),
          }, corsHeaders());
        }
        const next = await configStore.patch(patch);
        return json(res, 200, publicConfig(next), corsHeaders());
      }
      return methodNotAllowed(res);
    }

    if (pathname === '/api/pair') {
      if (req.method !== 'POST') return methodNotAllowed(res);
      try {
        const result = await issueClientToken(configStore, await readJson(req));
        return json(res, 201, result, corsHeaders());
      } catch (error) {
        return json(res, error.status ?? 500, {
          error: 'pairing_failed',
          message: String(error?.message ?? error),
        }, corsHeaders());
      }
    }

    if (pathname === '/api/adblock/check') {
      if (req.method !== 'POST') return methodNotAllowed(res);
      const body = await readJson(req);
      const blocked = isBlockedUrl(body.url, configStore.get().features.adblock);
      return json(res, 200, { blocked }, corsHeaders());
    }

    if (pathname === '/api/proxy') {
      if (req.method !== 'GET') return methodNotAllowed(res);
      const target = url.searchParams.get('url');
      if (!target) {
        return json(res, 400, { error: 'missing_url' }, corsHeaders());
      }
      return await proxyUrl({
        req,
        res,
        url: target,
        config: configStore.get(),
        fetchFunction,
      });
    }

    if (pathname === '/api/search') {
      if (req.method !== 'GET') return methodNotAllowed(res);
      const query = url.searchParams.get('q') ?? '';
      if (!query) return json(res, 400, { error: 'missing_query' }, corsHeaders());
      const type = url.searchParams.get('type') ?? undefined;
      const result = await youtubeService.search(query, type ? { type } : {});
      return json(res, 200, withSectionPlaybackUrls(result, baseUrl), corsHeaders());
    }

    if (pathname === '/api/playlist/search' || pathname === '/api/browse/related') {
      if (req.method !== 'POST') return methodNotAllowed(res);
      const body = await readJson(req);
      const result = pathname === '/api/playlist/search'
        ? await youtubeService.playlistSearch(body.media, String(body.query ?? '').slice(0, 200))
        : await youtubeService.browseRelated(body.media, body.kind);
      return json(res, 200, withSectionPlaybackUrls(result, baseUrl), corsHeaders());
    }

    if (pathname === '/api/search/suggestions') {
      if (req.method !== 'GET') return methodNotAllowed(res);
      const query = url.searchParams.get('q') ?? '';
      const suggestions = query ? await youtubeService.suggestions(query) : [];
      return json(res, 200, { suggestions }, corsHeaders());
    }

    if (pathname === '/api/home') {
      if (req.method !== 'GET') return methodNotAllowed(res);
      return json(res, 200, withSectionPlaybackUrls(await youtubeService.home(), baseUrl), corsHeaders());
    }

    if (pathname === '/api/explore') {
      if (req.method !== 'GET') return methodNotAllowed(res);
      return json(res, 200, withSectionPlaybackUrls(await youtubeService.explore(), baseUrl), corsHeaders());
    }

    if (pathname === '/api/library') {
      if (req.method !== 'GET') return methodNotAllowed(res);
      return json(res, 200, withSectionPlaybackUrls(await youtubeService.library(), baseUrl), corsHeaders());
    }

    if (pathname === '/api/browse') {
      if (req.method !== 'POST') return methodNotAllowed(res);
      const body = await readJson(req);
      return json(
        res,
        200,
        withSectionPlaybackUrls(await youtubeService.browse(body.media ?? body, { paged: body.paged === true, continuation: body.continuation ?? null }), baseUrl),
        corsHeaders(),
      );
    }

    const playlistMatch = pathname.match(/^\/api\/playlist\/([^/]+)$/);
    if (playlistMatch) {
      if (req.method !== 'GET') return methodNotAllowed(res);
      return json(
        res,
        200,
        withMediaPlaybackUrls(await youtubeService.playlist(playlistMatch[1]), baseUrl),
        corsHeaders(),
      );
    }

    const mediaMatch = pathname.match(/^\/api\/media\/([^/]+)$/);
    if (mediaMatch) {
      if (req.method !== 'GET') return methodNotAllowed(res);
      const media = await youtubeService.track(mediaMatch[1]);
      return json(res, 200, withMediaPlaybackUrls(media, baseUrl), corsHeaders());
    }

    const ratingMatch = pathname.match(/^\/api\/media\/([^/]+)\/rating$/);
    if (ratingMatch) {
      if (req.method !== 'PUT') return methodNotAllowed(res);
      if (!clientForRequest(configStore, req)) {
        return json(res, 403, {
          error: 'pairing_required',
          message: 'Pair this TV client before updating YouTube ratings.',
        }, corsHeaders());
      }
      try {
        const body = await readJson(req);
        const likeStatus = String(body.likeStatus ?? '').toUpperCase();
        if (!['LIKE', 'DISLIKE', 'INDIFFERENT'].includes(likeStatus)) {
          return json(res, 400, {
            error: 'invalid_like_status',
            message: 'likeStatus must be LIKE, DISLIKE, or INDIFFERENT.',
          }, corsHeaders());
        }
        const result = await youtubeService.setRating(ratingMatch[1], likeStatus);
        return json(res, 200, result, corsHeaders());
      } catch (error) {
        return json(res, error.status ?? 502, {
          error: error.code ?? 'youtube_rating_failed',
          message: String(error?.message ?? error),
        }, corsHeaders());
      }
    }

    const mixMatch = pathname.match(/^\/api\/media\/([^/]+)\/mix$/);
    if (mixMatch) {
      if (req.method !== 'GET') return methodNotAllowed(res);
      return json(res, 200, withSectionPlaybackUrls(await youtubeService.mix(mixMatch[1]), baseUrl), corsHeaders());
    }

    const relatedMatch = pathname.match(/^\/api\/media\/([^/]+)\/related$/);
    if (relatedMatch) {
      if (req.method !== 'GET') return methodNotAllowed(res);
      return json(
        res,
        200,
        withSectionPlaybackUrls(await youtubeService.related(relatedMatch[1]), baseUrl),
        corsHeaders(),
      );
    }

    const resolveMatch = pathname.match(/^\/api\/resolve\/([^/]+)$/);
    if (resolveMatch) {
      if (req.method !== 'GET') return methodNotAllowed(res);
      const media = {
        id: resolveMatch[1],
        videoId: resolveMatch[1],
        title: resolveMatch[1],
        artist: '',
      };
      try {
        const config = configStore.get();
        const playbackOptions = playbackOptionsFromRequest(url, config);
        const resolved = await youtubeService.resolveStream(media, {
          preferVideo: playbackOptions.preferVideo,
          quality: playbackOptions.quality,
        });
        return json(res, 200, {
          ...resolved,
          proxyUrl: publicStreamUrl(baseUrl, media.id, playbackOptions),
          adaptiveVideoProxyUrl: resolved.adaptiveVideoUrl
            ? publicStreamUrl(baseUrl, media.id, { ...playbackOptions, component: 'video' })
            : null,
          adaptiveAudioProxyUrl: resolved.adaptiveAudioUrl
            ? publicStreamUrl(baseUrl, media.id, { ...playbackOptions, component: 'audio' })
            : null,
        }, corsHeaders());
      } catch (error) {
        return streamResolveFailure(res, error);
      }
    }

    const streamMatch = pathname.match(/^\/api\/stream\/([^/]+)$/);
    if (streamMatch) {
      if (req.method !== 'GET' && req.method !== 'HEAD') return methodNotAllowed(res);
      try {
        const config = configStore.get();
        return await streamResolvedMedia({
          req,
          res,
          media: {
            id: streamMatch[1],
            videoId: streamMatch[1],
            title: streamMatch[1],
            artist: '',
          },
          config,
          youtubeService,
          playbackOptions: playbackOptionsFromRequest(url, config),
          playbackComponent: url.searchParams.get('component'),
          fetchFunction,
        });
      } catch (error) {
        return streamResolveFailure(res, error);
      }
    }

    return notFound(res);
  };
};

const withMediaPlaybackUrls = (value, baseUrl) => {
  if (Array.isArray(value)) {
    return value.map((item) => withMediaPlaybackUrls(item, baseUrl));
  }
  if (!value || typeof value !== 'object') return value;
  if ('items' in value && Array.isArray(value.items)) {
    return {
      ...value,
      items: value.items.map((item) => withMediaPlaybackUrls(item, baseUrl)),
    };
  }
  if ('id' in value) {
    return {
      ...value,
      playbackUrl: publicStreamUrl(baseUrl, value.videoId ?? value.id),
    };
  }
  return value;
};

const withSectionPlaybackUrls = (value, baseUrl) => ({
  ...value,
  sections: (value.sections ?? []).map((section) => ({
    ...section,
    items: section.items.map((item) => withMediaPlaybackUrls(item, baseUrl)),
  })),
});

const corsHeaders = () => ({
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET,HEAD,POST,PUT,PATCH,OPTIONS',
  'access-control-allow-headers': 'authorization,content-type,range',
});

const playbackOptionsFromRequest = (url, config) => {
  const preferVideoQuery = url.searchParams.get('preferVideo');
  return {
    preferVideo: preferVideoQuery == null
      ? config.playback.preferVideo
      : preferVideoQuery !== 'false',
    quality: url.searchParams.get('quality') ?? config.playback.defaultQuality,
  };
};

const streamResolveFailure = (res, error) =>
  json(res, error.status ?? 502, {
    error: error.code ?? 'stream_resolve_failed',
    message: String(error?.message ?? error),
  }, corsHeaders());

const publicConfig = (config) => ({
  features: config.features,
  playback: config.playback,
  network: {
    proxy: publicProxyConfig(config.network?.proxy),
  },
});

const publicConfigPatch = (patch) => {
  const next = {
    ...(patch.features ? { features: patch.features } : {}),
    ...(patch.playback ? { playback: patch.playback } : {}),
  };
  if (patch.network) {
    next.network = proxyConfigPatch(patch.network);
  }
  return next;
};
