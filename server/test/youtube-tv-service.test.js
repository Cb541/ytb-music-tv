import assert from 'node:assert/strict';
import test from 'node:test';

import { normalizeTvTile, YouTubeTvService } from '../src/services/youtube-tv-service.js';

test('builds YouTube Music Library sections from OAuth-authenticated TV renderers', async () => {
  const credentials = [];
  const client = fakeClient(({ browseId }) => {
    const items = {
      FEmusic_last_played: [videoTile('abcdefghijk', 'Listen again song', 'Example artist')],
      FEmusic_liked_playlists: [playlistTile('VLLM', 'Liked Music')],
      FEmusic_liked_albums: [],
      FEmusic_liked_videos: [videoTile('lmnopqrstuv', 'Liked song', 'Liked artist')],
      FEmusic_library_corpus_artists: [],
    }[browseId];
    assert.ok(items, `unexpected browse id: ${browseId}`);
    return successful(musicPage(browseId, items));
  }, credentials);
  const service = new YouTubeTvService({
    oauth: fakeOAuth(),
    clientFactory: async () => client,
  });

  const library = await service.library();

  assert.equal(library.provider, 'youtube-music-tv-oauth');
  assert.deepEqual(library.sections.map((section) => section.title), ['Listen again', 'Playlists', 'Songs']);
  assert.equal(library.sections[0].items[0].videoId, 'abcdefghijk');
  assert.equal(library.sections[0].items[0].artist, 'Example artist');
  assert.equal(library.sections[0].items[0].durationMs, 183_000);
  assert.equal(library.sections[0].items[0].likeStatus, 'INDIFFERENT');
  assert.equal(library.sections[1].items[0].playlistId, 'VLLM');
  assert.equal(library.sections[2].items[0].likeStatus, 'LIKE');
  assert.equal(credentials[0].access_token, 'access-token');
  assert.equal(client.session.logged_in, true);
});

test('loads playlist continuations and normalizes TV tiles', async () => {
  const requests = [];
  const client = fakeClient((payload) => {
    requests.push(payload);
    if (payload.browseId) {
      return successful({
        contents: {
          tvBrowseRenderer: {
            content: {
              tvSurfaceContentRenderer: {
                content: {
                  twoColumnRenderer: {
                    leftColumn: { entityMetadataRenderer: { title: { simpleText: 'Liked videos' } } },
                    rightColumn: {
                      playlistVideoListRenderer: {
                        contents: [videoTile('abcdefghijk', 'First song', 'First artist')],
                        continuations: [{ nextContinuationData: { continuation: 'next-page' } }],
                      },
                    },
                  },
                },
              },
            },
          },
        },
      });
    }
    return successful({
      continuationContents: {
        playlistVideoListContinuation: {
          contents: [videoTile('lmnopqrstuv', 'Second song', 'Second artist')],
        },
      },
    });
  });
  const service = new YouTubeTvService({
    oauth: fakeOAuth(),
    clientFactory: async () => client,
  });

  const playlist = await service.playlist('LL');

  assert.equal(playlist.id, 'VLLL');
  assert.equal(playlist.title, 'Liked videos');
  assert.deepEqual(playlist.items.map((item) => item.videoId), ['abcdefghijk', 'lmnopqrstuv']);
  assert.ok(playlist.items.every((item) => item.likeStatus === 'LIKE'));
  assert.equal(requests[1].token, 'next-page');
});

test('normalizes playlist browse ids without treating them as playable videos', () => {
  const item = normalizeTvTile(playlistTile('VLPL123', 'Road trip').tileRenderer);
  assert.equal(item.videoId, null);
  assert.equal(item.browseId, 'VLPL123');
  assert.equal(item.playlistId, 'VLPL123');
  assert.equal(item.type, 'playlist');
});

test('writes likes, dislikes, and rating removal through the authenticated TV client', async () => {
  const calls = [];
  const client = {
    interact: {
      like: async (videoId) => {
        calls.push(['like', videoId]);
        return successful({});
      },
      dislike: async (videoId) => {
        calls.push(['dislike', videoId]);
        return successful({});
      },
      removeRating: async (videoId) => {
        calls.push(['removeRating', videoId]);
        return successful({});
      },
    },
    session: {
      logged_in: false,
      oauth: { setTokens: () => {} },
    },
  };
  const service = new YouTubeTvService({
    oauth: fakeOAuth(),
    clientFactory: async () => client,
  });

  assert.deepEqual(await service.setRating('abcdefghijk', 'LIKE'), {
    videoId: 'abcdefghijk',
    likeStatus: 'LIKE',
  });
  await service.setRating('abcdefghijk', 'DISLIKE');
  await service.setRating('abcdefghijk', 'INDIFFERENT');

  assert.deepEqual(calls, [
    ['like', 'abcdefghijk'],
    ['dislike', 'abcdefghijk'],
    ['removeRating', 'abcdefghijk'],
  ]);
  assert.equal(client.session.logged_in, true);
});

test('rejects rating updates made with legacy read-only OAuth credentials', async () => {
  const service = new YouTubeTvService({
    oauth: {
      ...fakeOAuth(),
      status: () => ({
        status: 'configured',
        scope: 'https://www.googleapis.com/auth/youtube.readonly',
      }),
    },
    clientFactory: async () => {
      throw new Error('client should not be created');
    },
  });

  await assert.rejects(
    service.setRating('abcdefghijk', 'LIKE'),
    (error) => error.code === 'oauth_write_scope_required' && error.status === 403,
  );
});

const fakeOAuth = () => ({
  status: () => ({
    status: 'configured',
    hasRefreshToken: true,
    expiresAt: new Date(Date.now() + 3_600_000).toISOString(),
  }),
  accessToken: async () => 'access-token',
});

const fakeClient = (execute, credentials = []) => ({
  actions: { execute: async (_endpoint, payload) => execute(payload) },
  session: {
    logged_in: false,
    oauth: { setTokens: (tokens) => credentials.push(tokens) },
  },
});

const successful = (data) => ({ success: true, status_code: 200, data });

const musicPage = (browseId, items) => ({
  contents: {
    tvBrowseRenderer: {
      content: {
        tvSecondaryNavRenderer: {
          sections: [{
            tvSecondaryNavSectionRenderer: {
              tabs: [{
                tabRenderer: {
                  selected: true,
                  endpoint: { browseEndpoint: { browseId } },
                  content: {
                    tvSurfaceContentRenderer: {
                      content: { gridRenderer: { items } },
                    },
                  },
                },
              }],
            },
          }],
        },
      },
    },
  },
});

const videoTile = (videoId, title, artist = '') => ({
  tileRenderer: {
    header: {
      tileHeaderRenderer: {
        thumbnail: { thumbnails: [{ url: `https://img.example/${videoId}.jpg`, width: 480, height: 360 }] },
        thumbnailOverlays: [{
          thumbnailOverlayTimeStatusRenderer: { text: { simpleText: '3:03' } },
        }],
      },
    },
    metadata: {
      tileMetadataRenderer: {
        title: { simpleText: title },
        lines: [{
          lineRenderer: {
            items: [{ lineItemRenderer: { text: { simpleText: artist } } }],
          },
        }],
      },
    },
    onSelectCommand: { watchEndpoint: { videoId, playlistId: 'LM' } },
    contentId: videoId,
    contentType: 'TILE_CONTENT_TYPE_VIDEO',
  },
});

const playlistTile = (browseId, title) => ({
  tileRenderer: {
    metadata: { tileMetadataRenderer: { title: { simpleText: title } } },
    onSelectCommand: { browseEndpoint: { browseId } },
    contentId: browseId.replace(/^VL/, ''),
    contentType: 'TILE_CONTENT_TYPE_PLAYLIST',
  },
});
