import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { loadConfig } from '../src/lib/config.js';

test('server identity and six-digit device code persist across restarts', async () => {
  const dataDir = await mkdtemp(join(tmpdir(), 'ytb-music-tv-'));

  try {
    const firstStore = await loadConfig(dataDir);
    const first = firstStore.get();
    assert.match(first.security.deviceCode, /^\d{6}$/);
    assert.ok(first.security.serverId);
    assert.deepEqual(first.network.proxy, {
      enabled: false,
      url: '',
      noProxy: ['localhost', '127.0.0.1', '::1'],
    });
    assert.equal('auth' in first, false);

    const secondStore = await loadConfig(dataDir);
    const second = secondStore.get();
    assert.equal(second.security.deviceCode, first.security.deviceCode);
    assert.equal(second.security.serverId, first.security.serverId);

    const persisted = JSON.parse(await readFile(join(dataDir, 'config.json'), 'utf8'));
    assert.equal(persisted.security.deviceCode, first.security.deviceCode);
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});
