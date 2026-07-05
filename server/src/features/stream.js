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

  await proxyUrl({
    req,
    res,
    url: resolved.directUrl,
    config,
    fetchFunction,
    onUpstreamFailure: async ({ status }) => {
      if (!isRecoverableMediaStatus(status)) {
        return null;
      }

      youtubeService.invalidateStream?.(media.videoId, options);
      if (options.preferVideo === false) {
        const refreshed = await youtubeService.resolveStream(media, options);
        if (refreshed.directUrl && refreshed.directUrl !== resolved.directUrl) {
          return refreshed.directUrl;
        }
        return null;
      }

      const audioOptions = {
        ...options,
        preferVideo: false,
      };
      youtubeService.invalidateStream?.(media.videoId, audioOptions);
      const audio = await youtubeService.resolveStream(media, audioOptions);
      return audio.directUrl ?? null;
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
  return url.toString();
};

const isRecoverableMediaStatus = (status) => [403, 404, 410].includes(status);
