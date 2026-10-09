import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { access, mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const active = new Map();
const MAX_JOBS = 5;
const IDLE_MS = 45 * 60 * 1000;
const START_TIMEOUT_MS = 30_000;
const FFMPEG = process.env.YTB_MUSIC_TV_FFMPEG || 'ffmpeg';

// A mid/side-only, 30% stereo-width increase. No temporal delays,
// reverberation or phase manipulation. 0.88 output level adds headroom.
const STEREO_FILTER = 'aformat=channel_layouts=stereo,stereotools=slev=1.30:mlev=1:level_out=0.88';

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const cleanExpired = async () => {
  for (const [key, entry] of active) {
    if (Date.now() - entry.accessed < IDLE_MS) continue;
    active.delete(key);
    const job = await entry.promise.catch(() => null);
    if (!job) continue;
    if (job.process && job.process.exitCode === null) {
      job.process.kill('SIGTERM');
    }
    await rm(job.directory, { recursive: true, force: true }).catch(() => {});
  }
};

const isVideoId = (id) => /^[a-zA-Z0-9_-]{11}$/.test(id || '');

async function initialize(videoId, youtubeService) {
  const resolved = await youtubeService.resolveStream(
    { id: videoId, videoId, title: videoId, artist: '' },
    { preferVideo: false, quality: 'best' },
  );
  const source = resolved.adaptiveAudioUrl ?? resolved.directUrl;
  if (!source || !/^https?:\/\//i.test(source)) {
    throw new Error('No usable audio stream found');
  }

  const directory = await mkdtemp(join(tmpdir(), 'ytb-spatial-'));
  const manifest = join(directory, 'index.m3u8');
  const args = [
    '-nostdin', '-hide_banner', '-loglevel', 'error',
    '-rw_timeout', '16000000',
    '-i', source,
    '-map', '0:a:0', '-vn', '-sn', '-dn',
    '-af', STEREO_FILTER,
    '-ar', '48000', '-ac', '2', '-c:a', 'aac', '-b:a', '256k',
    '-f', 'hls', '-hls_time', '3', '-hls_list_size', '0',
    '-hls_playlist_type', 'event', '-hls_flags', 'independent_segments+temp_file',
    '-hls_segment_filename', join(directory, '%05d.ts'),
    manifest,
  ];

  const job = {
    directory,
    manifest,
    process: null,
    accessed: Date.now(),
    completed: false,
    failed: null,
    done: null,
    finalManifest: null,
  };
  // FFmpeg receives the signed input URL as an argv entry; never include its
  // potentially sensitive query parameters in the client response or log.
  const child = spawn(FFMPEG, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  job.process = child;
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr = (stderr + chunk.toString()).slice(-2000); });
  job.done = new Promise((resolve, reject) => {
    child.on('error', (error) => {
      job.failed = new Error(error.code === 'ENOENT' ? 'FFmpeg is not installed' : 'Unable to start audio processor');
      reject(job.failed);
    });
    child.on('close', (code) => {
      job.completed = code === 0;
      if (code === 0) resolve();
      else {
        job.failed = new Error('Audio processor stopped before completing the stream');
        // Never print signed URLs or ffmpeg stderr; ffmpeg can echo source URLs.
        reject(job.failed);
      }
    });
  });
  // Avoid unhandled rejection while the HLS client is reading segments.
  job.done.catch(() => {});
  return job;
}

async function getJob(videoId, youtubeService) {
  if (!isVideoId(videoId)) {
    const error = new Error('Invalid video ID');
    error.status = 400;
    throw error;
  }
  await cleanExpired();
  let entry = active.get(videoId);
  if (!entry) {
    if (active.size >= MAX_JOBS) {
      const error = new Error('Spatial stream processor is busy; normal audio remains available');
      error.status = 503;
      throw error;
    }
    const promise = initialize(videoId, youtubeService).catch((error) => {
      active.delete(videoId);
      throw error;
    });
    entry = { promise, accessed: Date.now() };
    active.set(videoId, entry);
  }
  entry.accessed = Date.now();
  const job = await entry.promise;
  job.accessed = Date.now();
  return job;
}

const awaitManifest = async (job, { complete = false } = {}) => {
  if (job.finalManifest) return job.finalManifest;
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (job.failed) throw job.failed;
    if (complete && !job.completed) {
      await wait(100);
      continue;
    }
    try {
      const body = await readFile(job.manifest);
      if (body.includes(Buffer.from('#EXTINF:')) && (!complete || body.includes(Buffer.from('#EXT-X-ENDLIST')))) {
        if (job.completed && body.includes(Buffer.from('#EXT-X-ENDLIST'))) {
          job.finalManifest = body;
        }
        return body;
      }
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    await wait(100);
  }
  throw new Error('Spatial audio preparation exceeded the startup deadline');
};

export const serveSpatialStream = async ({ req, res, videoId, filename, youtubeService }) => {
  const headers = {
    'access-control-allow-origin': '*',
    'cache-control': 'no-store',
  };
  try {
    if (!['GET', 'HEAD'].includes(req.method)) {
      res.writeHead(405, headers); res.end(); return;
    }
    if (filename !== 'index.m3u8' && filename !== 'ready' && !/^\d{5}\.ts$/.test(filename)) {
      res.writeHead(404, headers); res.end(); return;
    }

    const job = await getJob(videoId, youtubeService);
    if (filename === 'ready') {
      await awaitManifest(job, { complete: true });
      res.writeHead(200, { ...headers, 'content-type': 'text/plain; charset=utf-8' });
      res.end(req.method === 'HEAD' ? undefined : 'ready');
      return;
    }
    if (filename === 'index.m3u8') {
      const manifest = await awaitManifest(job);
      res.writeHead(200, {
        ...headers,
        'content-type': 'application/vnd.apple.mpegurl',
        'content-length': manifest.length,
      });
      res.end(req.method === 'HEAD' ? undefined : manifest);
      return;
    }
    const segment = join(job.directory, filename);
    const information = await stat(segment);
    if (!information.isFile()) throw new Error('Segment is not a file');
    res.writeHead(200, {
      ...headers, 'content-type': 'video/mp2t',
      'content-length': information.size,
    });
    if (req.method === 'HEAD') res.end();
    else createReadStream(segment).on('error', () => res.destroy()).pipe(res);
  } catch (error) {
    if (res.headersSent) { res.destroy(); return; }
    const status = error.status || (error.code === 'ENOENT' ? 404 : 503);
    res.writeHead(status, { ...headers, 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'spatial_unavailable', message: error.message }));
  }
};

export const spatialStreamURL = (baseURL, videoId) =>
  new URL('/api/spatial/' + encodeURIComponent(videoId) + '/index.m3u8', baseURL).toString();
