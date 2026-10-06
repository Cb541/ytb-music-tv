import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  libraryFromParsedResponse,
  selectTvOSFormats,
  upgradeMusicAudio,
  cookieHeaderFromNetscape,
  boundedMusicInfo,
  YouTubeMusicService,
} from '../src/services/youtube-service.js';

test('uses the OAuth-backed YouTube TV service for Library', async () => {
  const expected = {
    provider: 'youtube-music-tv-oauth',
    filters: [],
    sortOptions: [],
    sections: [],
  };
  const service = new YouTubeMusicService({
    configStore: { get: () => ({ youtube: {} }) },
    sessionStore: sessionStore(),
    oauthLibraryService: {
      authStatus: () => ({ status: 'configured', hasRefreshToken: true }),
      library: async () => expected,
    },
  });

  assert.equal(service.authStatus().mode, 'google-device-oauth');
  assert.deepEqual(await service.library(), expected);
});

test('delegates YouTube rating updates to the configured OAuth service', async () => {
  const updates = [];
  const service = new YouTubeMusicService({
    configStore: { get: () => ({ youtube: {} }) },
    sessionStore: sessionStore(),
    oauthLibraryService: {
      authStatus: () => ({ status: 'configured', hasRefreshToken: true }),
      setRating: async (videoId, likeStatus) => {
        updates.push({ videoId, likeStatus });
        return { videoId, likeStatus };
      },
    },
  });

  assert.deepEqual(await service.setRating('abcdefghijk', 'LIKE'), {
    videoId: 'abcdefghijk',
    likeStatus: 'LIKE',
  });
  assert.deepEqual(updates, [{ videoId: 'abcdefghijk', likeStatus: 'LIKE' }]);
});

test('rejects YouTube rating updates without OAuth login', async () => {
  const service = new YouTubeMusicService({
    configStore: { get: () => ({ youtube: {} }) },
    sessionStore: sessionStore(),
  });

  await assert.rejects(
    service.setRating('abcdefghijk', 'LIKE'),
    (error) => error.code === 'oauth_required' && error.status === 401,
  );
});

const sessionStore = () => ({
  get: () => ({ poToken: '', visitorData: '', updatedAt: null }),
  patch: async () => {},
  clear: async () => {},
});

test('normalizes an empty ItemSection library response', () => {
  const parsed = {
    contents_memo: {
      getType: () => [],
    },
  };

  assert.deepEqual(libraryFromParsedResponse(parsed), {
    filters: [],
    sortOptions: [],
    sections: [],
  });
});

test('selects adaptive H.264 video and AAC audio at the requested tvOS quality', () => {
  const audio = format({ has_audio: true, mime_type: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 192_000 });
  const progressive = format({
    has_audio: true,
    has_video: true,
    height: 360,
    mime_type: 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
  });
  const video480 = format({
    has_video: true,
    height: 480,
    mime_type: 'video/mp4; codecs="avc1.4d401f"',
  });
  const video720 = format({
    has_video: true,
    height: 720,
    mime_type: 'video/mp4; codecs="avc1.4d401f"',
  });
  const video1080 = format({
    has_video: true,
    height: 1080,
    mime_type: 'video/mp4; codecs="avc1.640028"',
  });
  const info = {
    streaming_data: {
      formats: [progressive],
      adaptive_formats: [audio, video480, video720, video1080],
    },
  };

  const best = selectTvOSFormats(info, { preferVideo: true, quality: 'best' });
  assert.equal(best.playback, progressive);
  assert.equal(best.video, video1080);
  assert.equal(best.audio, audio);

  const capped = selectTvOSFormats(info, { preferVideo: true, quality: '720p' });
  assert.equal(capped.video, video720);

  const efficient = selectTvOSFormats(info, { preferVideo: true, quality: 'bestefficiency' });
  assert.equal(efficient.video, progressive);
  assert.equal(efficient.audio, audio);
});

const format = (values) => ({ bitrate: 1, has_audio: false, has_video: false, ...values });

test('selects highest AAC bitrate for audio-only and video without tying audio to resolution', () => {
  const low = format({ has_audio: true, mime_type: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 48000 });
  const high = format({ has_audio: true, mime_type: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 256000 });
  const opus = format({ has_audio: true, mime_type: 'audio/webm; codecs="opus"', bitrate: 300000 });
  const progressive = format({ has_audio: true, has_video: true, height: 720, mime_type: 'video/mp4; codecs="avc1, mp4a.40.2"' });
  const video = format({ has_video: true, height: 720, mime_type: 'video/mp4; codecs="avc1"' });
  const info = { streaming_data: { formats: [progressive], adaptive_formats: [low, high, opus, video] } };
  assert.equal(selectTvOSFormats(info, { preferVideo: false }).playback, high);
  const withVideo = selectTvOSFormats(info, { preferVideo: true });
  assert.equal(withVideo.audio, high); assert.equal(withVideo.video, video);
  info.streaming_data.adaptive_formats = [low, high];
  const muxed = selectTvOSFormats(info, { preferVideo: true });
  assert.equal(muxed.video, progressive); assert.equal(muxed.audio, high);
  info.streaming_data.adaptive_formats = [];
  assert.equal(selectTvOSFormats(info, { preferVideo: true }).playback, progressive);
});

test('Music audio upgrade preserves TV video and falls back when better AAC is unavailable', async () => {
  const low = format({ has_audio: true, mime_type: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 128000 });
  const high = { ...low, bitrate: 256000 };
  const video = format({ has_video: true, height: 1080, mime_type: 'video/mp4; codecs="avc1"' });
  const makeInfo = () => ({ streaming_data: { formats: [], adaptive_formats: [low, video] } });
  const info = makeInfo();
  assert.equal(await upgradeMusicAudio(info, async () => ({ streaming_data: { adaptive_formats: [high] } })), info);
  assert.equal(selectTvOSFormats(info, { preferVideo: true }).audio, high);
  assert.equal(selectTvOSFormats(info, { preferVideo: true }).video, video);
  let called = false;
  await upgradeMusicAudio(info, async () => { called = true; }); assert.equal(called, false);
  for (const fetch of [async () => { throw Error('unavailable'); }, async () => ({}), async () => ({ streaming_data: { adaptive_formats: [{ ...low, bitrate: 48000 }] } })]) {
    const original = makeInfo(); await upgradeMusicAudio(original, fetch);
    assert.equal(selectTvOSFormats(original, { preferVideo: false }).playback, low);
  }
});

test('slow Music quality lookup returns the working stream within its deadline and ignores late results', async () => {
  const low = format({ has_audio: true, mime_type: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 128000 });
  const high = { ...low, bitrate: 256000 };
  const info = { streaming_data: { adaptive_formats: [low] } };
  let finish;
  const pending = new Promise(resolve => { finish = resolve; });
  const began = Date.now();
  assert.equal(await upgradeMusicAudio(info, () => pending, { timeoutMs: 20 }), info);
  assert.ok(Date.now() - began < 1000, 'working audio must not wait for a stalled lookup');
  assert.equal(selectTvOSFormats(info, { preferVideo: false }).playback, low);
  finish({ streaming_data: { adaptive_formats: [high] } });
  await Promise.resolve(); await Promise.resolve();
  assert.equal(selectTvOSFormats(info, { preferVideo: false }).playback, low);
});

test('cookie import restricts exports to current YouTube root cookies and excludes header injection', () => {
  const row = (domain, name, value, expiry = 2000000000, path = '/') => [domain, 'TRUE', path, 'TRUE', expiry, name, value].join('\t');
  const header = cookieHeaderFromNetscape([
    '# Netscape HTTP Cookie File',
    '#HttpOnly_' + row('.youtube.com', 'SAPISID', 'test-secret'),
    row('.youtube.com', 'SID', 'session', 0),
    row('.google.com', 'OTHER', 'unrelated'),
    row('.youtube.com.evil.test', 'OTHER', 'unrelated'),
    row('.youtube.com', 'EXPIRED', 'old', 1),
    row('.youtube.com', 'NESTED', 'private', 2000000000, '/other'),
    row('.youtube.com', 'INVALID', 'one; Cookie: injected'),
  ].join('\r\n'), { now: 100000 });
  assert.equal(header, 'SAPISID=test-secret; SID=session');
  assert.equal(cookieHeaderFromNetscape(row('.google.com', 'SAPISID', 'no')), '');
  assert.equal(cookieHeaderFromNetscape(row('.youtube.com', 'SID', 'no')), '');
  assert.throws(() => cookieHeaderFromNetscape('x'.repeat(131073)));
});

test('bounded Music lookup tolerates failed requests and returns null for stalled requests', async () => {
  assert.equal(await boundedMusicInfo(async () => { throw Error('HTTP 400'); }), null);
  assert.equal(await boundedMusicInfo(() => new Promise(() => {}), { timeoutMs: 10 }), null);
});

test('playback deadlines abort network work and do not cancel concurrent browsing', async () => {
  let playbackAborted = false;
  const signals = [];
  const service = new YouTubeMusicService({
    configStore: { get: () => ({ youtube: {} }) }, sessionStore: sessionStore(), cookieFile: '',
    fetchFunction: async (url, { signal } = {}) => {
      signals.push(signal);
      if (url.endsWith('/search')) return {};
      return new Promise((resolve, reject) => signal?.addEventListener('abort', () => {
        playbackAborted = true; reject(signal.reason);
      }, { once: true }));
    },
    clientFactory: async (options) => ({ session: {},
      getBasicInfo: () => options.fetch('https://example.test/player'),
      music: { search: async () => { await options.fetch('https://example.test/search'); return {}; } },
    }),
  });
  const playback = boundedMusicInfo(() => service.resolveStream({ videoId: 'deadline-song' }), { timeoutMs: 25 });
  // Browsing runs outside the playback deadline and must receive no new signal.
  const browsing = service.search('test');
  assert.equal(await playback, null);
  assert.equal(playbackAborted, true);
  assert.ok(signals.some((signal) => signal?.aborted));
  assert.ok(signals.includes(undefined));
  await browsing;
});

test('playable responses without compatible audio continue through fallback clients', async () => {
  const calls = [];
  const audio = format({ has_audio: true, mime_type: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000,
    url: 'https://example.test/audio', decipher: async () => 'https://example.test/audio' });
  const service = new YouTubeMusicService({
    configStore: { get: () => ({ youtube: {} }) }, sessionStore: sessionStore(), cookieFile: '',
    clientFactory: async () => ({ session: {}, getBasicInfo: async (_, { client }) => {
      calls.push(client);
      return { basic_info: { id: 'test', title: 'Test' }, playability_status: { status: 'OK' },
        streaming_data: { formats: [], adaptive_formats: client === 'WEB' ? [audio] : [] } };
    } }),
  });
  assert.equal((await service.resolveStream({ videoId: 'fallback-song' }, { preferVideo: false })).audioBitrate, 130000);
  assert.deepEqual(calls, ['YTMUSIC', 'ANDROID', 'WEB']);
});

test('cookie audio bypasses TV OAuth, reloads cookies, and retains fallback playback', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'ytb-cookies-test-'));
  const cookieFile = join(dir, 'cookies.txt');
  const low = format({ has_audio: true, mime_type: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000,
    url: 'https://example.test/low', decipher: async () => 'https://example.test/low' });
  const high = { ...low, bitrate: 256000, url: 'https://example.test/high', decipher: async () => 'https://example.test/high' };
  const info = (audio) => ({ basic_info: { id: 'test-song', title: 'Test' },
    playability_status: { status: 'OK' }, streaming_data: { formats: [], adaptive_formats: [audio] } });
  const factoryOptions = [], oauthClients = [];
  let tvFails = false, cookieFails = false, cookieCalls = 0;
  const writeCookies = (value) => writeFile(cookieFile, `.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\t${value}\n`);
  const service = new YouTubeMusicService({
    configStore: { get: () => ({ youtube: {} }) }, sessionStore: sessionStore(), cookieFile,
    oauthLibraryService: { authStatus: () => ({ status: 'configured' }), authorizeSession: async (client) => { oauthClients.push(client); } },
    clientFactory: async (options) => {
      factoryOptions.push(options);
      return { session: { player: { signature_timestamp: 123 } }, getBasicInfo: async (_, { client }) => {
        if (options.cookie) {
          cookieCalls += 1;
          assert.equal(client, 'YTMUSIC');
          if (cookieFails) throw Error('Music unavailable');
          return info(high);
        }
        assert.equal(client, 'TV', 'a TV OAuth session must not request the Music client');
        if (tvFails) throw Error('TV unavailable');
        return info(low);
      } };
    },
  });
  try {
    await writeCookies('test-one');
    assert.equal((await service.resolveStream({ videoId: 'song-one' }, { preferVideo: false })).audioBitrate, 256000);
    assert.equal(factoryOptions.filter((o) => o.cookie).length, 1);
    assert.equal(factoryOptions[0].client_type, 'TVHTML5');
    assert.equal(factoryOptions[1].client_type, 'WEB_REMIX');
    assert.equal(factoryOptions[1].retrieve_innertube_config, false);
    assert.equal(oauthClients.length, 0, "cookie audio must bypass TV OAuth entirely");
    await writeCookies('test-two');
    tvFails = true;
    assert.equal((await service.resolveStream({ videoId: 'song-two' }, { preferVideo: false })).audioBitrate, 256000);
    assert.equal(factoryOptions.filter((o) => o.cookie).length, 2);
    assert.ok(factoryOptions.find((o) => o.cookie === 'SAPISID=test-two'));
    await rm(cookieFile);
    tvFails = false;
    assert.equal((await service.resolveStream({ videoId: 'song-three' }, { preferVideo: false })).audioBitrate, 130000);
    assert.equal(service.authStatus().hasCookie, false);
    assert.equal(oauthClients.length, 1, 'missing cookies must retain TV OAuth fallback');
    await writeCookies('test-three');
    cookieFails = true;
    const previousCookieCalls = cookieCalls;
    assert.equal((await service.resolveStream({ videoId: 'song-four' }, { preferVideo: false })).audioBitrate, 130000);
    assert.equal(cookieCalls - previousCookieCalls, 1, 'failed Music lookup must not be repeated before fallback');
    assert.equal(oauthClients.length, 2);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('failed or unplayable cookie Music results preserve working TV audio', async () => {
  const low = format({ has_audio: true, mime_type: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000 });
  const original = { streaming_data: { adaptive_formats: [low] } };
  await upgradeMusicAudio(original, async () => ({ playability_status: { status: 'ERROR' }, streaming_data: { adaptive_formats: [{ ...low, bitrate: 256000 }] } }));
  assert.equal(selectTvOSFormats(original, { preferVideo: false }).playback, low);
});
