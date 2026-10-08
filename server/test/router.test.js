import assert from 'node:assert/strict';
import test from 'node:test';

import { createApiRouter } from '../src/lib/router.js';

const config = {
  security: {
    serverId: 'server-test-id',
    deviceCode: '123456',
    clients: [],
  },
  features: {
    adblock: { enabled: true },
    skipDislikedSongs: { enabled: true },
  },
  playback: {
    selectedLibrary: null,
    preferVideo: true,
    defaultQuality: 'best',
    streamMode: 'proxy',
  },
};

test('anonymous clients can connect and paired clients are identified', async () => {
  const router = makeRouter();

  const anonymousHealth = createResponse();
  await router(createRequest('GET', '/api/health'), anonymousHealth);
  assert.equal(anonymousHealth.status, 200);
  assert.equal(JSON.parse(anonymousHealth.body).associated, false);

  const invalidPairing = createResponse();
  await router(
    createRequest('POST', '/api/pair', { deviceCode: '000000' }),
    invalidPairing,
  );
  assert.equal(invalidPairing.status, 403);

  const pairing = createResponse();
  await router(
    createRequest('POST', '/api/pair', { name: 'Living Room', deviceCode: '123456' }),
    pairing,
  );
  assert.equal(pairing.status, 201);
  const token = JSON.parse(pairing.body).token;

  const pairedHealth = createResponse();
  await router(createRequest('GET', '/api/health', null, token), pairedHealth);
  assert.equal(pairedHealth.status, 200);
  const status = JSON.parse(pairedHealth.body);
  assert.equal(status.associated, true);
  assert.equal(status.client.name, 'Living Room');
  assert.equal(status.authenticated, false);
});

test('public config excludes and cannot modify device identity', async () => {
  const store = createConfigStore();
  const router = makeRouter({}, store);

  const getResponse = createResponse();
  await router(createRequest('GET', '/api/config'), getResponse);
  assert.equal(getResponse.status, 200);
  assert.equal('security' in JSON.parse(getResponse.body), false);

  const patchResponse = createResponse();
  await router(
    createRequest('PATCH', '/api/config', {
      security: { deviceCode: '999999' },
      features: { adblock: { enabled: false } },
    }),
    patchResponse,
  );
  assert.equal(patchResponse.status, 200);
  assert.equal(store.get().security.deviceCode, '123456');
  assert.equal(store.get().features.adblock.enabled, false);
});

test('proxy config changes require a paired client and redact credentials', async () => {
  const store = createConfigStore();
  const router = makeRouter({}, store);

  const anonymousPatch = createResponse();
  await router(
    createRequest('PATCH', '/api/config', {
      network: {
        proxy: {
          enabled: true,
          url: 'http://user:secret@127.0.0.1:7890',
        },
      },
    }),
    anonymousPatch,
  );
  assert.equal(anonymousPatch.status, 403);

  const pairing = createResponse();
  await router(
    createRequest('POST', '/api/pair', { name: 'Living Room', deviceCode: '123456' }),
    pairing,
  );
  const token = JSON.parse(pairing.body).token;

  const pairedPatch = createResponse();
  await router(
    createRequest('PATCH', '/api/config', {
      network: {
        proxy: {
          enabled: true,
          url: 'http://user:secret@127.0.0.1:7890',
          noProxy: ['localhost', '.local'],
        },
      },
    }, token),
    pairedPatch,
  );

  assert.equal(pairedPatch.status, 200);
  assert.equal(store.get().network.proxy.url, 'http://user:secret@127.0.0.1:7890');
  const payload = JSON.parse(pairedPatch.body);
  assert.equal(payload.network.proxy.url, 'http://user:***@127.0.0.1:7890/');
  assert.deepEqual(payload.network.proxy.noProxy, ['localhost', '.local']);
});

test('proxy config rejects invalid proxy URLs', async () => {
  const store = createConfigStore();
  const router = makeRouter({}, store);
  const pairing = createResponse();
  await router(
    createRequest('POST', '/api/pair', { name: 'Living Room', deviceCode: '123456' }),
    pairing,
  );
  const token = JSON.parse(pairing.body).token;

  const response = createResponse();
  await router(
    createRequest('PATCH', '/api/config', {
      network: {
        proxy: {
          enabled: true,
          url: 'ftp://proxy.example',
        },
      },
    }, token),
    response,
  );

  assert.equal(response.status, 400);
  assert.equal(JSON.parse(response.body).error, 'invalid_proxy_config');
  assert.equal(store.get().network, undefined);
});

test('legacy server-owned playback endpoints are no longer exposed', async () => {
  const router = makeRouter();

  for (const [method, url] of [
    ['GET', '/api/player/state'],
    ['POST', '/api/play'],
    ['GET', '/api/queue'],
    ['POST', '/api/player/pause'],
    ['GET', '/api/events'],
  ]) {
    const response = createResponse();
    await router(createRequest(method, url), response);
    assert.equal(response.status, 404, `${method} ${url}`);
    assert.deepEqual(JSON.parse(response.body), { error: 'not_found' });
  }
});

test('YouTube rating updates require pairing and forward the requested status', async () => {
  const updates = [];
  const store = createConfigStore();
  const router = makeRouter({
    setRating: async (videoId, likeStatus) => {
      updates.push({ videoId, likeStatus });
      return { videoId, likeStatus };
    },
  }, store);

  const anonymous = createResponse();
  await router(
    createRequest('PUT', '/api/media/abcdefghijk/rating', { likeStatus: 'LIKE' }),
    anonymous,
  );
  assert.equal(anonymous.status, 403);

  const pairing = createResponse();
  await router(
    createRequest('POST', '/api/pair', { name: 'Living Room', deviceCode: '123456' }),
    pairing,
  );
  const token = JSON.parse(pairing.body).token;

  const invalid = createResponse();
  await router(
    createRequest('PUT', '/api/media/abcdefghijk/rating', { likeStatus: 'favorite' }, token),
    invalid,
  );
  assert.equal(invalid.status, 400);

  const response = createResponse();
  await router(
    createRequest('PUT', '/api/media/abcdefghijk/rating', { likeStatus: 'dislike' }, token),
    response,
  );
  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(response.body), {
    videoId: 'abcdefghijk',
    likeStatus: 'DISLIKE',
  });
  assert.deepEqual(updates, [{ videoId: 'abcdefghijk', likeStatus: 'DISLIKE' }]);
});

test('stream resolution is stateless and keyed by video id', async () => {
  let resolvedMedia;
  let resolvedOptions;
  const router = makeRouter({
    resolveStream: async (media, options) => {
      resolvedMedia = media;
      resolvedOptions = options;
      return {
        videoId: media.videoId,
        directUrl: 'https://media.example/video.mp4',
        adaptiveVideoUrl: 'https://media.example/video-1080.mp4',
        adaptiveAudioUrl: 'https://media.example/audio.m4a',
        hasAudio: true,
        hasVideo: true,
      };
    },
  });

  const response = createResponse();
  await router(createRequest('GET', '/api/resolve/video123456'), response);

  assert.equal(response.status, 200);
  assert.equal(resolvedMedia.videoId, 'video123456');
  assert.equal(resolvedOptions.preferVideo, true);
  const payload = JSON.parse(response.body);
  assert.equal(payload.videoId, 'video123456');
  assert.equal(payload.proxyUrl, 'http://ytb.local/api/stream/video123456?preferVideo=true&quality=best');
  assert.equal(
    payload.adaptiveVideoProxyUrl,
    'http://ytb.local/api/stream/video123456?preferVideo=true&quality=best&component=video',
  );
  assert.equal(
    payload.adaptiveAudioProxyUrl,
    'http://ytb.local/api/stream/video123456?preferVideo=true&quality=best&component=audio',
  );
});

test('media details are resolved by video id', async () => {
  const requested = [];
  const router = makeRouter({
    track: async (videoId) => {
      requested.push(videoId);
      return {
        id: videoId,
        videoId,
        title: 'Example',
        artist: 'Artist',
      };
    },
  });
  const response = createResponse();

  await router(createRequest('GET', '/api/media/video123456'), response);

  assert.equal(response.status, 200);
  assert.deepEqual(requested, ['video123456']);
  assert.equal(JSON.parse(response.body).videoId, 'video123456');
});

test('stream resolution accepts an audio-only fallback request', async () => {
  let resolvedOptions;
  const router = makeRouter({
    resolveStream: async (media, options) => {
      resolvedOptions = options;
      return {
        videoId: media.videoId,
        directUrl: 'https://media.example/audio.m4a',
        hasAudio: true,
        hasVideo: false,
      };
    },
  });

  const response = createResponse();
  await router(createRequest('GET', '/api/resolve/video123456?preferVideo=false'), response);

  assert.equal(response.status, 200);
  assert.equal(resolvedOptions.preferVideo, false);
  const payload = JSON.parse(response.body);
  assert.equal(payload.proxyUrl, 'http://ytb.local/api/stream/video123456?preferVideo=false&quality=best');
});

test('stream endpoint preserves requested playback preference', async () => {
  const restoreFetch = globalThis.fetch;
  const fetchedUrls = [];
  globalThis.fetch = async (url) => {
    fetchedUrls.push(String(url));
    return new Response('ok', { status: 200 });
  };

  let resolvedOptions;
  const router = makeRouter({
    resolveStream: async (media, options) => {
      resolvedOptions = options;
      return {
        videoId: media.videoId,
        directUrl: 'https://media.example/audio.m4a',
        hasAudio: true,
        hasVideo: false,
      };
    },
  });

  try {
    const response = createResponse();
    await router(createRequest('GET', '/api/stream/video123456?preferVideo=false'), response);

    assert.equal(response.status, 200);
    assert.equal(resolvedOptions.preferVideo, false);
    assert.deepEqual(fetchedUrls, ['https://media.example/audio.m4a']);
  } finally {
    globalThis.fetch = restoreFetch;
  }
});

test('stream endpoint proxies adaptive video and audio components independently', async () => {
  const restoreFetch = globalThis.fetch;
  const fetchedUrls = [];
  globalThis.fetch = async (url) => {
    fetchedUrls.push(String(url));
    return new Response('ok', { status: 200 });
  };
  const router = makeRouter({
    resolveStream: async (media) => ({
      videoId: media.videoId,
      directUrl: 'https://media.example/progressive.mp4',
      adaptiveVideoUrl: 'https://media.example/video-1080.mp4',
      adaptiveAudioUrl: 'https://media.example/audio.m4a',
      hasAudio: true,
      hasVideo: true,
    }),
  });

  try {
    const video = createResponse();
    await router(createRequest('GET', '/api/stream/video123456?component=video'), video);
    const audio = createResponse();
    await router(createRequest('GET', '/api/stream/video123456?component=audio'), audio);

    assert.equal(video.status, 200);
    assert.equal(audio.status, 200);
    assert.deepEqual(fetchedUrls, [
      'https://media.example/video-1080.mp4',
      'https://media.example/audio.m4a',
    ]);
  } finally {
    globalThis.fetch = restoreFetch;
  }
});

test('stream endpoint refreshes failed video URLs and falls back to audio', async () => {
  const restoreFetch = globalThis.fetch;
  const fetchedUrls = [];
  globalThis.fetch = async (url) => {
    fetchedUrls.push(String(url));
    if (fetchedUrls.length === 1) {
      return new Response('forbidden', { status: 403 });
    }
    return new Response('ok', { status: 200 });
  };

  const invalidated = [];
  const resolvedOptions = [];
  const router = makeRouter({
    resolveStream: async (media, options) => {
      resolvedOptions.push(options);
      if (options.preferVideo === false) {
        return {
          videoId: media.videoId,
          directUrl: 'https://media.example/audio.m4a',
          hasAudio: true,
          hasVideo: false,
        };
      }
      return {
        videoId: media.videoId,
        directUrl: 'https://media.example/video.mp4',
        hasAudio: true,
        hasVideo: true,
      };
    },
    invalidateStream: (videoId, options) => {
      invalidated.push({ videoId, options });
      return true;
    },
  });

  try {
    const response = createResponse();
    await router(createRequest('GET', '/api/stream/video123456'), response);

    assert.equal(response.status, 200);
    assert.equal(response.body, 'ok');
    assert.deepEqual(fetchedUrls, [
      'https://media.example/video.mp4',
      'https://media.example/audio.m4a',
    ]);
    assert.deepEqual(
      resolvedOptions.map((options) => [options.preferVideo, options.skipOAuth === true]),
      [[true, false], [true, false], [true, true], [false, true]],
    );
    assert.deepEqual(
      invalidated.map((entry) => [entry.options.preferVideo, entry.options.skipOAuth === true]),
      [[true, false], [true, true], [false, true]],
    );
  } finally {
    globalThis.fetch = restoreFetch;
  }
});

test('stream recovery stops after finite OAuth, anonymous, and audio attempts', async () => {
  const restoreFetch = globalThis.fetch;
  const fetchedUrls = [];
  globalThis.fetch = async (url) => {
    fetchedUrls.push(String(url));
    return new Response('forbidden', { status: 403 });
  };
  let resolution = 0;
  const router = makeRouter({
    resolveStream: async (media, options) => {
      resolution += 1;
      const kind = options.preferVideo === false
        ? 'audio-anonymous'
        : options.skipOAuth === true ? 'video-anonymous' : 'video-oauth';
      return {
        videoId: media.videoId,
        directUrl: `https://media.example/${kind}-${resolution}.mp4`,
        hasAudio: true,
        hasVideo: options.preferVideo !== false,
      };
    },
    invalidateStream: () => true,
  });

  try {
    const response = createResponse();
    await router(createRequest('GET', '/api/stream/video123456'), response);

    assert.equal(response.status, 403);
    assert.equal(fetchedUrls.length, 4);
    assert.deepEqual(fetchedUrls, [
      'https://media.example/video-oauth-1.mp4',
      'https://media.example/video-oauth-2.mp4',
      'https://media.example/video-anonymous-3.mp4',
      'https://media.example/audio-anonymous-4.mp4',
    ]);
  } finally {
    globalThis.fetch = restoreFetch;
  }
});

const makeRouter = (youtubeOverrides = {}, configStore = createConfigStore()) => createApiRouter({
  configStore,
  youtubeService: {
    authStatus: () => ({ status: 'not_configured' }),
    ...youtubeOverrides,
  },
});

const createConfigStore = () => {
  let current = structuredClone(config);
  return {
    get: () => structuredClone(current),
    patch: async (patch) => {
      current = merge(current, patch);
      return structuredClone(current);
    },
    replace: async (next) => {
      current = structuredClone(next);
      return structuredClone(current);
    },
  };
};

const merge = (base, patch) => {
  const output = structuredClone(base);
  for (const [key, value] of Object.entries(patch)) {
    output[key] = value && typeof value === 'object' && !Array.isArray(value)
      ? merge(output[key] ?? {}, value)
      : structuredClone(value);
  }
  return output;
};

const createRequest = (method, url, body = null, accessToken = null) => {
  const request = {
    method,
    url,
    headers: {
      host: 'ytb.local',
      ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
    },
  };
  if (body != null) {
    request[Symbol.asyncIterator] = async function* requestBody() {
      yield Buffer.from(JSON.stringify(body));
    };
  }
  return request;
};

const createResponse = () => ({
  status: null,
  headers: null,
  body: '',
  writeHead(status, headers) {
    this.status = status;
    this.headers = headers;
  },
  write(chunk) {
    this.body += Buffer.from(chunk).toString('utf8');
  },
  end(body = '') {
    this.body += body;
  },
});

test('category search and new read-only browsing routes forward their parameters', async () => {
  const calls = [];
  const router = makeRouter({
    search: async (query, filters) => { calls.push(['search', query, filters.type]); return { sections: [] }; },
    playlistSearch: async (media, query) => { calls.push(['playlist', media.id, query]); return { sections: [], playbackQueue: [] }; },
    browseRelated: async (media, kind) => { calls.push(['related', media.artist, kind]); return { sections: [] }; },
  });
  for (const type of ['all', 'song', 'artist', 'album', 'playlist', 'featured_playlist', 'community_playlist']) {
    const res = createResponse(); await router(createRequest('GET', '/api/search?q=Artist&type=' + type), res); assert.equal(res.status, 200);
  }
  for (const [path, body] of [['/api/playlist/search', { media: { id: 'PLtest' }, query: 'song' }], ['/api/browse/related', { media: { artist: 'Artist' }, kind: 'artist' }]]) {
    const res = createResponse(); await router(createRequest('POST', path, body), res); assert.equal(res.status, 200);
  }
  assert.deepEqual(calls.slice(-2), [['playlist', 'PLtest', 'song'], ['related', 'Artist', 'artist']]);
});

test('song mix route returns playable recommendations and rejects mutations', async () => {
  const calls = [];
  const router = makeRouter({ mix: async (id) => { calls.push(id); return { sections: [{ id: 'mix', title: 'Mix', items: [{ id: 'bbbbbbbbbbb', videoId: 'bbbbbbbbbbb' }] }] }; } });
  const res = createResponse(); await router(createRequest('GET', '/api/media/aaaaaaaaaaa/mix'), res);
  assert.equal(res.status, 200);
  assert.deepEqual(calls, ['aaaaaaaaaaa']);
  assert.match(JSON.parse(res.body).sections[0].items[0].playbackUrl, /bbbbbbbbbbb/);
  const rejected = createResponse(); await router(createRequest('POST', '/api/media/aaaaaaaaaaa/mix'), rejected);
  assert.equal(rejected.status, 405);
});

test('song resolution proxies the matched recording and forces highest audio only', async () => {
  const original = { videoId: 'aaaaaaaaaaa', title: 'Song', artist: 'Artist' };
  const official = { videoId: 'bbbbbbbbbbb', title: 'Song', artist: 'Artist', album: 'Album', artworkUrl: 'https://img.example/album.jpg' };
  const router = makeRouter({
    officialSong: async (media) => { assert.deepEqual(media, original); return official; },
    resolveStream: async (media, options) => {
      assert.equal(media.videoId, official.videoId); assert.deepEqual(options, { preferVideo: false, quality: 'best' });
      return { videoId: official.videoId, directUrl: 'https://audio.example/official.m4a', audioBitrate: 258000, hasVideo: false, media: { title: 'Song' } };
    },
  });
  const response = createResponse();
  await router(createRequest('POST', '/api/resolve-song', { media: original }), response);
  assert.equal(response.status, 200);
  const body = JSON.parse(response.body);
  assert.equal(body.media.videoId, official.videoId); assert.equal(body.audioBitrate, 258000);
  assert.match(body.proxyUrl, /bbbbbbbbbbb/); assert.match(body.proxyUrl, /preferVideo=false/);
  assert.equal(body.media.artworkUrl, official.artworkUrl);
});
