import assert from 'node:assert/strict';
import test from 'node:test';

import {
  libraryFromParsedResponse,
  selectTvOSFormats,
  upgradeMusicAudio,
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
