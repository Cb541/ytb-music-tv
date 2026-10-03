import assert from 'node:assert/strict';
import test from 'node:test';
import { YouTubeMusicService, artistSections } from '../src/services/youtube-service.js';
import { normalizeMediaNode, normalizeSearch } from '../src/services/media-normalizer.js';
const service = () => new YouTubeMusicService({ configStore: { get: () => ({ youtube: {} }) }, sessionStore: { get: () => ({}) } });

test('related pages prefer supplied IDs and recover when a stored link is stale', async () => {
  const api = service(); const calls = [];
  api.search = async () => { calls.push('search'); return { sections: [{ items: [{ id: 'UCfresh', title: 'Artist' }] }] }; };
  api.browse = async ({ id }) => { calls.push(id); if (id === 'UCstale') throw Error('gone'); return { title: id, sections: [] }; };
  assert.equal((await api.browseRelated({ artist: 'Artist', artistBrowseId: 'UCdirect' }, 'artist')).title, 'UCdirect');
  assert.deepEqual(calls, ['UCdirect']); calls.length = 0;
  await api.browseRelated({ artist: 'Artist – Topic', artistBrowseId: 'UCstale' }, 'artist');
  assert.deepEqual(calls, ['UCstale', 'search', 'UCfresh']); calls.length = 0;
  assert.equal((await api.browseRelated({ albumBrowseId: 'MPRdirect' }, 'album')).title, 'MPRdirect');
  assert.deepEqual(calls, ['MPRdirect']);
});

test('album discovery accepts an alternate ID for the same recording and rejects wrong versions', async () => {
  const { sameRecording } = await import('../src/services/youtube-service.js');
  const media = { id: 'song', title: 'Artist - Song (Official Audio)', artist: 'Artist - Topic', durationMs: 180000 };
  const alternate = { videoId: 'other', title: 'Song', artist: 'Artist', durationMs: 181000, albumBrowseId: 'MPRrecording' };
  assert.equal(sameRecording(alternate, media), true);
  assert.equal(sameRecording({ ...alternate, artist: 'Cover band' }, media), false);
  assert.equal(sameRecording({ ...alternate, title: 'Song (Live)' }, media), false);
  assert.equal(sameRecording({ ...alternate, durationMs: 220000 }, media), false);
  const api = service(); let chosen;
  api.search = async () => ({ sections: [{ items: [{ ...alternate, artist: 'Cover band' }, alternate] }] });
  api.browse = async (item) => { chosen = item; return { sections: [] }; };
  await api.browseRelated(media, 'album'); assert.equal(chosen.id, 'MPRrecording');
});

test('album searches normalize Topic artists and include the artist in the query', async () => {
  const api = service(); const queries = [];
  api.search = async (q, { type }) => { queries.push([q, type]); return { sections: [{ items: type === 'song' ? [] : [
    { id: 'MPRwrong', title: 'Album', artist: 'Other' }, { id: 'MPRright', title: 'Album', artist: 'Artist' },
  ] }] }; };
  api.browse = async ({ id }) => ({ title: id, sections: [] });
  assert.equal((await api.browseRelated({ title: 'Song', artist: 'Artist — Topic', album: 'Album' }, 'album')).title, 'MPRright');
  assert.deepEqual(queries, [['Song Artist', 'song'], ['Album Artist', 'album']]);
});

test('album tracks inherit covers and links without replacing an individual cover', async () => {
  const { albumSections } = await import('../src/services/youtube-service.js');
  const result = albumSections({ header: { title: 'Album', author: { name: 'Artist', channel_id: 'UCartist' },
    thumbnail: { contents: [{ url: 'https://img.example/album.jpg', width: 1000, height: 1000 }] } }, contents: [
      { id: 'aaaaaaaaaaa', title: 'First' },
      { id: 'bbbbbbbbbbb', title: 'Second', thumbnail: { musicThumbnailRenderer: { thumbnail: { thumbnails: [{ url: 'https://img.example/track.jpg' }] } } } },
    ] }, {}, 'MPRalbum');
  assert.equal(result[0].items[0].artworkUrl, 'https://img.example/album.jpg');
  assert.equal(result[0].items[1].artworkUrl, 'https://img.example/track.jpg');
  assert.equal(result[0].items[0].artist, 'Artist');
  assert.equal(result[0].items[0].artistBrowseId, 'UCartist');
  assert.equal(result[0].items[0].albumBrowseId, 'MPRalbum');
  assert.equal(result[0].items[0].type, 'song');
});

test('flat navigation payloads and nested thumbnails survive normalization', () => {
  const album = normalizeMediaNode({ item_type: 'album', title: 'Album', endpoint: { payload: { browseId: 'MPRalbum' } },
    thumbnail: { contents: [{ url: 'https://img.example/small.jpg', width: 10, height: 10 }, { url: 'https://img.example/large.jpg', width: 300, height: 300 }] } });
  assert.equal(album.id, 'MPRalbum'); assert.equal(album.browseId, 'MPRalbum'); assert.equal(album.playlistId, null);
  assert.equal(album.artworkUrl, 'https://img.example/large.jpg');
  const song = normalizeMediaNode({ title: 'Song', endpoint: { payload: { videoId: 'abcdefghijk' } },
    artists: [{ name: 'Artist', channel_id: 'UCartist' }], album: { name: 'Album', endpoint: { payload: { browseId: 'MPRalbum' } } } });
  assert.equal(song.videoId, 'abcdefghijk'); assert.equal(song.artistBrowseId, 'UCartist'); assert.equal(song.albumBrowseId, 'MPRalbum');
  assert.equal(normalizeMediaNode({ title: 'Song', thumbnail: { contents: 'bad' } }).artworkUrl, null);
});

test('Up next supplies the exact album when search has no matching recording', async () => {
  const api = new YouTubeMusicService({ configStore: { get: () => ({ youtube: {} }) }, sessionStore: { get: () => ({}) },
    clientFactory: async () => ({ music: { getUpNext: async () => ({ contents: [
      { video_id: 'wrongwrong1', album: { id: 'MPRwrong' } },
      { video_id: 'abcdefghijk', album: { id: 'MPRexact', name: 'Album' } },
    ] }) } }) });
  api.search = async () => ({ sections: [] }); api.browse = async ({ id }) => ({ title: id, sections: [] });
  assert.equal((await api.browseRelated({ videoId: 'abcdefghijk', title: 'Song', artist: 'Artist' }, 'album')).title, 'MPRexact');
});

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

test('song mix uses YouTube automix and retains different artists in recommendation order', async () => {
  const { recommendedMix } = await import('../src/services/youtube-service.js');
  const calls = [];
  const music = { getUpNext: async (...args) => { calls.push(args); return { contents: [
    { video_id: 'aaaaaaaaaaa', title: 'Seed' },
    { video_id: 'bbbbbbbbbbb', title: 'Similar', author: 'Other artist', duration: { seconds: 240 }, thumbnail: [{ url: 'https://img.example/cover.jpg', width: 100 }] },
    { type: 'AutomixPreviewVideo' },
    { video_id: 'bbbbbbbbbbb', title: 'Duplicate' },
    { video_id: 'ccccccccccc', title: 'Another', artists: [{ name: 'Third artist' }] },
  ] }; } };
  const result = await recommendedMix(music, 'aaaaaaaaaaa');
  assert.deepEqual(calls, [['aaaaaaaaaaa', true]]);
  assert.deepEqual(result.sections[0].items.map(item => item.videoId), ['bbbbbbbbbbb', 'ccccccccccc']);
  assert.deepEqual(result.sections[0].items.map(item => item.artist), ['Other artist', 'Third artist']);
  assert.equal(result.sections[0].items[0].durationMs, 240000);
  assert.equal(result.sections[0].items[0].artworkUrl, 'https://img.example/cover.jpg');
  await assert.rejects(recommendedMix({ getUpNext: async () => { throw Error('unavailable'); } }, 'aaaaaaaaaaa'), /unavailable/);
});
