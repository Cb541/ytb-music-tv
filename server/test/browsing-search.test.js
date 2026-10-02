import assert from 'node:assert/strict';
import test from 'node:test';
import { YouTubeMusicService, artistSections } from '../src/services/youtube-service.js';
import { normalizeMediaNode, normalizeSearch } from '../src/services/media-normalizer.js';
const service = () => new YouTubeMusicService({ configStore: { get: () => ({ youtube: {} }) }, sessionStore: { get: () => ({}) } });

test('entire-playlist search shares an in-flight scan and preserves full playback order', async () => {
  const api = service(); let scans = 0;
  const songs = [{ id: 'first', title: 'Other', artist: 'Artist' }, { id: 'last', title: 'Café Song', artist: 'Artist' }];
  api.playlist = async () => { scans++; await new Promise((resolve) => setTimeout(resolve, 10)); return { items: songs }; };
  const [a, b] = await Promise.all([api.playlistSearch({ id: 'PLtest' }, 'CAFE'), api.playlistSearch({ id: 'PLtest' }, 'Artist')]);
  assert.equal(scans, 1); assert.deepEqual(a.sections[0].items, [songs[1]]);
  assert.deepEqual(a.playbackQueue, songs); assert.deepEqual(b.sections[0].items, songs);
  await api.playlistSearch({ id: 'PLtest' }, 'Other'); assert.equal(scans, 1);
});

test('failed playlist scans can be retried', async () => {
  const api = service(); let calls = 0;
  api.playlist = async () => { if (++calls === 1) throw new Error('offline'); return { items: [] }; };
  await assert.rejects(api.playlistSearch({ id: 'PLtest' }, 'song'), /offline/);
  await api.playlistSearch({ id: 'PLtest' }, 'song'); assert.equal(calls, 2);
});

test('artist destination requires an exact match and strips the Topic suffix', async () => {
  const api = service(); let query; let chosen;
  api.search = async (q, filter) => { query = [q, filter.type]; return { sections: [{ items: [{ id: 'wrong', title: 'Pink Floyd Tribute' }, { id: 'UCright', title: 'Pink Floyd' }] }] }; };
  api.browse = async (item) => { chosen = item; return { sections: [] }; };
  await api.browseRelated({ artist: 'Pink Floyd - Topic' }, 'artist');
  assert.deepEqual(query, ['Pink Floyd', 'artist']); assert.equal(chosen.id, 'UCright');
  await assert.rejects(api.browseRelated({ artist: 'Different' }, 'artist'), /exact artist/);
});

test('album destination uses the matching song album endpoint when metadata is absent', async () => {
  const api = service(); let chosen;
  api.search = async () => ({ sections: [{ items: [{ videoId: 'song', albumBrowseId: 'MPRalbum' }, { videoId: 'other', albumBrowseId: 'MPRwrong' }] }] });
  api.browse = async (item) => { chosen = item; return { sections: [] }; };
  await api.browseRelated({ id: 'song', title: 'Song', artist: 'Artist' }, 'album');
  assert.equal(chosen.id, 'MPRalbum');
});

test('artist song preview expands without dropping album sections', async () => {
  const preview = { title: 'Top songs', contents: [{ id: 'abcdefghijk', title: 'First' }] };
  const album = { title: 'Albums', contents: [{ id: 'MPRalbum', title: 'Album', item_type: 'album' }] };
  const result = await artistSections({ sections: [preview, album], getAllSongs: async () => ({ contents: [...preview.contents, { id: 'bcdefghijkl', title: 'Second' }] }) });
  assert.equal(result[0].items.length, 2); assert.equal(result[1].title, 'Albums');
  const fallback = await artistSections({ sections: [preview], getAllSongs: async () => { throw new Error('no endpoint'); } });
  assert.equal(fallback[0].items.length, 1);
});

test('album browse identifiers and community playlist shelves survive normalization', () => {
  const song = normalizeMediaNode({ id: 'abcdefghijk', title: 'Song', album: { name: 'Album', id: 'MPRalbum' } });
  assert.equal(song.albumBrowseId, 'MPRalbum');
  const result = normalizeSearch({ contents: [{ title: 'Community playlists', contents: [{ id: 'PLcommunity', title: 'Mix', item_type: 'playlist' }] }] });
  assert.equal(result.sections[0].items[0].playlistId, 'PLcommunity');
});

test('public playlist search follows continuation pages in playback order', async () => {
  const { fullPlaylistItems } = await import('../src/services/youtube-service.js');
  const second = { items: [{ id: 'bbbbbbbbbbb', title: 'Second', item_type: 'song' }] };
  const first = { items: [{ id: 'aaaaaaaaaaa', title: 'First', item_type: 'song' }], has_continuation: true, getContinuation: async () => second };
  assert.deepEqual((await fullPlaylistItems(first)).map(item => item.title), ['First', 'Second']);
  assert.equal((await fullPlaylistItems(first, 1)).length, 1);
});
