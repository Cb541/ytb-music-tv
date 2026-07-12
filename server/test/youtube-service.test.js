import assert from 'node:assert/strict';
import test from 'node:test';

import {
  libraryFromParsedResponse,
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
