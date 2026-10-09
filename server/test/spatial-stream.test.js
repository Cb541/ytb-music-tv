import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { serveSpatialStream } from '../src/features/spatial-stream.js';

const toolsPresent = ['ffmpeg', 'ffprobe'].every((cmd) =>
  spawnSync(cmd, ['-version'], { encoding: 'utf8' }).status === 0
);

test('spatial endpoint serves decoded playable HLS AAC segments', { skip: !toolsPresent }, async () => {
  const tmp = await mkdtemp(join(tmpdir(), 'ytb-spatial-test-'));
  const sample = join(tmp, 'source.wav');
  const generated = spawnSync('ffmpeg', [
    '-nostdin', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i',
    'aevalsrc=0.3*sin(2*PI*440*t)|0.2*sin(2*PI*880*t):s=48000:d=7',
    '-c:a', 'pcm_s16le', sample,
  ], { encoding: 'utf8', timeout: 10_000 });
  assert.equal(generated.status, 0, generated.stderr);

  const sourceServer = createServer(async (_req, res) => {
    const data = await readFile(sample);
    res.writeHead(200, { 'content-type': 'audio/wav', 'content-length': data.length });
    res.end(data);
  });
  sourceServer.listen(0, '127.0.0.1');
  await once(sourceServer, 'listening');
  const originalUrl = 'http://127.0.0.1:' + sourceServer.address().port + '/tone.wav';
  const musicService = {
    resolveStream: async () => ({ directUrl: originalUrl }),
  };

  const mediaServer = createServer(async (req, res) => {
    await serveSpatialStream({
      req, res, videoId: 'testMusic01',
      profile: req.url.split('/')[1] || 'balanced',
      filename: req.url.split('/').at(-1),
      youtubeService: musicService,
    });
  });
  mediaServer.listen(0, '127.0.0.1');
  await once(mediaServer, 'listening');
  const origin = 'http://127.0.0.1:' + mediaServer.address().port;
  const base = origin + '/balanced';

  try {
    const manifestResponse = await fetch(base + '/index.m3u8');
    assert.equal(manifestResponse.status, 200);
    assert.match(manifestResponse.headers.get('content-type'), /mpegurl/);
    const playlist = await manifestResponse.text();
    assert.match(playlist, /#EXTM3U/);
    assert.match(playlist, /#EXTINF/);

    const readyResponse = await fetch(base + '/ready', { signal: AbortSignal.timeout(32_000) });
    assert.equal(readyResponse.status, 200);
    const finalPlaylist = await (await fetch(base + '/index.m3u8')).text();
    assert.match(finalPlaylist, /#EXT-X-ENDLIST/);
    const name = finalPlaylist.match(/\b\d{5}\.ts\b/)?.[0];
    assert.ok(name, 'Missing HLS MPEG-TS segments');
    const segmentResponse = await fetch(base + '/' + name);
    assert.equal(segmentResponse.status, 200);
    const bytes = Buffer.from(await segmentResponse.arrayBuffer());
    assert.ok(bytes.length > 1000, 'Expected nonempty AAC segment');
    const segmentPath = join(tmp, 'segment.ts');
    await import('node:fs/promises').then((fs) => fs.writeFile(segmentPath, bytes));
    const probe = spawnSync('ffprobe', [
      '-v', 'error', '-select_streams', 'a:0',
      '-show_entries', 'stream=codec_name,channels,sample_rate',
      '-of', 'default=noprint_wrappers=1', segmentPath,
    ], { encoding: 'utf8', timeout: 10_000 });
    assert.equal(probe.status, 0, probe.stderr);
    assert.match(probe.stdout, /codec_name=aac/);
    assert.match(probe.stdout, /channels=2/);
    assert.match(probe.stdout, /sample_rate=48000/);
    // Verify all three distinct profiles are independently generated and
    // do not collide in the encoder/segment cache.
    for (const profile of ['immersive', 'maximum']) {
      const response = await fetch(origin + '/' + profile + '/ready', {
        signal: AbortSignal.timeout(32_000),
      });
      assert.equal(response.status, 200, profile + ' did not prepare');
      const manifest = await (await fetch(origin + '/' + profile + '/index.m3u8')).text();
      assert.match(manifest, /#EXT-X-ENDLIST/, profile + ' did not finalize');
      const file = manifest.match(/\\b\\d{5}\\.ts\\b/)?.[0];
      assert.ok(file, 'Missing ' + profile + ' segment');
      const segment = await fetch(origin + '/' + profile + '/' + file);
      assert.equal(segment.status, 200);
      assert.ok((await segment.arrayBuffer()).byteLength > 1000);
    }
  } finally {
    sourceServer.close();
    mediaServer.close();
    await rm(tmp, { recursive: true, force: true });
  }
});
