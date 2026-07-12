import { isBlockedUrl, proxyUrl } from './adblock.js';

export const streamMedia = async ({ req, res, media, config, baseUrl, fetchFunction = globalThis.fetch }) => {
  if (!media) {
    res.writeHead(404, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: 'media_not_found' }));
    return;
  }

  if (!media.streamUrl) {
    res.writeHead(501, { 'content-type': 'application/json; charset=utf-8' });
    res.end(
      JSON.stringify({
        error: 'stream_not_resolved',
        message:
          'Direct YouTube Music stream resolution is not implemented in this first slice. Supply media.streamUrl or add a resolver here.',
      }),
    );
    return;
  }

  if (isBlockedUrl(media.streamUrl, config.features.adblock)) {
    res.writeHead(403, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: 'blocked_by_adblock' }));
    return;
  }

  await proxyUrl({ req, res, url: media.streamUrl, config, fetchFunction });
};

export const streamResolvedMedia = async ({
  req,
  res,
  media,
  config,
  youtubeService,
  playbackOptions,
  playbackComponent = null,
  fetchFunction = globalThis.fetch,
}) => {
  if (!media) {
    res.writeHead(404, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: 'media_not_found' }));
    return;
  }

  if (media.streamUrl) {
    return await proxyUrl({ req, res, url: media.streamUrl, config, fetchFunction });
  }

  if (!media.videoId) {
    res.writeHead(422, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      error: 'not_playable',
      message: 'This item has no videoId. Select a song or video item.',
    }));
    return;
  }

  const options = {
    preferVideo: playbackOptions?.preferVideo ?? config.playback.preferVideo,
    quality: playbackOptions?.quality ?? config.playback.defaultQuality,
  };
  const resolved = await youtubeService.resolveStream(media, options);
  const resolvedUrl = playbackUrlForComponent(resolved, playbackComponent);
  if (!resolvedUrl) {
    res.writeHead(404, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      error: 'stream_component_unavailable',
      message: `The requested ${playbackComponent} stream is unavailable.`,
    }));
    return;
  }
  const attemptedUrls = new Set([resolvedUrl]);
  const recoveryOptions = [
    options,
    { ...options, skipOAuth: true },
    ...(!playbackComponent && options.preferVideo !== false
      ? [{ ...options, preferVideo: false, skipOAuth: true }]
      : []),
  ];
  let recoveryIndex = 0;

  await proxyUrl({
    req,
    res,
    url: resolvedUrl,
    config,
    fetchFunction,
    onUpstreamFailure: async ({ status }) => {
      if (!isRecoverableMediaStatus(status)) {
        return null;
      }

      while (recoveryIndex < recoveryOptions.length) {
        const nextOptions = recoveryOptions[recoveryIndex];
        recoveryIndex += 1;
        youtubeService.invalidateStream?.(media.videoId, nextOptions);
        const next = await youtubeService.resolveStream(media, nextOptions);
        const nextUrl = playbackUrlForComponent(next, playbackComponent);
        if (nextUrl && !attemptedUrls.has(nextUrl)) {
          attemptedUrls.add(nextUrl);
          return nextUrl;
        }
      }
      return null;
    },
  });
};

export const publicStreamUrl = (baseUrl, mediaId, options = {}) => {
  const url = new URL(`/api/stream/${encodeURIComponent(mediaId)}`, baseUrl);
  if (options.preferVideo != null) {
    url.searchParams.set('preferVideo', String(options.preferVideo));
  }
  if (options.quality) {
    url.searchParams.set('quality', options.quality);
  }
  if (options.component) {
    url.searchParams.set('component', options.component);
  }
  return url.toString();
};

const playbackUrlForComponent = (resolved, component) => {
  if (component === 'video') return resolved.adaptiveVideoUrl ?? null;
  if (component === 'audio') return resolved.adaptiveAudioUrl ?? null;
  return resolved.directUrl ?? null;
};

const isRecoverableMediaStatus = (status) => [403, 404, 410].includes(status);
