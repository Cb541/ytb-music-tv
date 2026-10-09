import { spawn } from 'node:child_process';

// Lightweight per-track tonal analysis. Never trust a generic "genre EQ":
// inspect the actual audio for an 8-second sample and apply bounded corrections.
// Corrections are heuristic and capped at +/- 3 dB to protect the mix.
const analysisCache = new Map();
const FFMPEG = process.env.YTB_MUSIC_TV_FFMPEG || 'ffmpeg';
const bands = [
  { name: 'low', filter: 'lowpass=f=180' },
  { name: 'mid', filter: 'highpass=f=220,lowpass=f=4000' },
  { name: 'high', filter: 'highpass=f=4500' },
];
const clamp = (x, low, high) => Math.min(high, Math.max(low, x));

function measureBand(source, filter) {
  return new Promise((resolve) => {
    const child = spawn(FFMPEG, [
      '-nostdin', '-hide_banner', '-loglevel', 'info', '-rw_timeout', '12000000',
      '-i', source, '-vn', '-sn', '-dn', '-t', '8',
      '-af', filter + ',volumedetect', '-f', 'null', '-',
    ], { stdio: ['ignore', 'ignore', 'pipe'] });
    let output = '';
    const timeout = setTimeout(() => child.kill('SIGKILL'), 13_000);
    child.stderr.on('data', (piece) => {
      output = (output + piece.toString()).slice(-1800);
    });
    child.on('error', () => { clearTimeout(timeout); resolve(null); });
    child.on('close', (exitCode) => {
      clearTimeout(timeout);
      const match = output.match(/mean_volume:\s*(-?\d+(?:\.\d+)?) dB/);
      resolve(exitCode === 0 && match ? Number(match[1]) : null);
    });
  });
}

export async function analyzeAutoEQ(videoId, source) {
  let cached = analysisCache.get(videoId);
  if (!cached) {
    cached = (async () => {
      const levels = await Promise.all(bands.map((band) => measureBand(source, band.filter)));
      if (levels.some((x) => x == null || !Number.isFinite(x))) {
        return { low: 0, mid: 0, high: 0, analyzed: false };
      }
      const [low, mid, high] = levels;
      // Low-band dominance can mask vocals; high-band deficits can dull
      // details. Compare low and high energy with the recording's mids.
      return {
        low: clamp((mid + 3 - low) * 0.28, -3, 2),
        mid: clamp((low - mid - 8) * 0.12, -1, 1.5),
        high: clamp((mid - high - 11) * 0.22, -1.5, 3),
        analyzed: true,
      };
    })().catch(() => ({ low: 0, mid: 0, high: 0, analyzed: false }));
    analysisCache.set(videoId, cached);
    if (analysisCache.size > 200) analysisCache.delete(analysisCache.keys().next().value);
  }
  return await cached;
}

export function autoEQFilter(gains) {
  const safe = (value) => clamp(Number(value) || 0, -3, 3).toFixed(2);
  return [
    'equalizer=f=110:t=q:w=0.8:g=' + safe(gains.low),
    'equalizer=f=1800:t=q:w=0.9:g=' + safe(gains.mid),
    'equalizer=f=8000:t=q:w=0.8:g=' + safe(gains.high),
    // Final chain applies a transparent peak limiter: don't permanently
    // attenuate every Auto EQ track by 18%.
  ].join(',');
}
