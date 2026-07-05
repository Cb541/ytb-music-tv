import assert from 'node:assert/strict';
import test from 'node:test';

import {
  createProxyFetch,
  effectiveProxyConfig,
  normalizeProxyConfig,
  publicProxyConfig,
} from '../src/lib/proxy-fetch.js';

test('proxy fetch attaches an agent for HTTP and SOCKS proxy URLs', async () => {
  const calls = [];
  const fetch = createProxyFetch({
    configStore: configStore({
      enabled: true,
      url: 'socks5://user:pass@127.0.0.1:1080',
      noProxy: [],
    }),
    fetchFunction: async (url, init) => {
      calls.push({ url, init });
      return new Response('ok');
    },
  });

  await fetch(new Request('https://music.youtube.com/youtubei/v1/search'));

  assert.equal(calls[0].url, 'https://music.youtube.com/youtubei/v1/search');
  assert.ok(calls[0].init.agent);
});

test('proxy fetch honors noProxy host suffixes', async () => {
  const calls = [];
  const fetch = createProxyFetch({
    configStore: configStore({
      enabled: true,
      url: 'http://127.0.0.1:7890',
      noProxy: ['youtube.com', '::1'],
    }),
    fetchFunction: async (url, init) => {
      calls.push({ url, init });
      return new Response('ok');
    },
  });

  await fetch('https://music.youtube.com/');
  await fetch('http://[::1]:4174/api/health');

  assert.equal(calls[0].url, 'https://music.youtube.com/');
  assert.equal(calls[0].init.agent, undefined);
  assert.equal(calls[1].url, 'http://[::1]:4174/api/health');
  assert.equal(calls[1].init.agent, undefined);
});

test('proxy config validates supported schemes and redacts credentials', () => {
  assert.deepEqual(normalizeProxyConfig({
    enabled: true,
    url: 'socks5h://user:pass@127.0.0.1:1080',
    noProxy: 'localhost,127.0.0.1',
  }), {
    enabled: true,
    url: 'socks5h://user:pass@127.0.0.1:1080',
    noProxy: ['localhost', '127.0.0.1'],
  });
  assert.equal(
    publicProxyConfig({
      enabled: true,
      url: 'http://user:secret@proxy.example:8080',
    }).url,
    'http://user:***@proxy.example:8080/',
  );
  assert.throws(
    () => normalizeProxyConfig({ enabled: true, url: 'ftp://proxy.example' }),
    { code: 'invalid_proxy_config' },
  );
});

test('YTB_MUSIC_TV_PROXY_URL overrides persisted proxy config', () => {
  const proxy = effectiveProxyConfig(
    { enabled: false, url: '', noProxy: [] },
    {
      YTB_MUSIC_TV_PROXY_URL: 'http://127.0.0.1:7890',
      YTB_MUSIC_TV_NO_PROXY: 'localhost,.local',
    },
  );

  assert.equal(proxy.enabled, true);
  assert.equal(proxy.url, 'http://127.0.0.1:7890');
  assert.deepEqual(proxy.noProxy, ['localhost', '.local']);
});

const configStore = (proxy) => ({
  get: () => ({
    network: { proxy },
  }),
});
