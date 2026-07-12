import assert from 'node:assert/strict';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { runOAuthLoginFlow } from '../src/lib/oauth-login-flow.js';
import { loadOAuthStore } from '../src/lib/oauth-store.js';
import { GoogleOAuthClient } from '../src/services/google-oauth.js';

test('device login stores refreshable credentials without exposing tokens', async () => {
  const store = memoryStore();
  const requests = [];
  const oauth = new GoogleOAuthClient({
    store,
    clientId: 'client-id',
    clientSecret: 'client-secret',
    now: () => Date.parse('2026-06-21T00:00:00.000Z'),
    waitFunction: async () => {},
    fetchFunction: async (url, options) => {
      requests.push({ url, body: Object.fromEntries(options.body) });
      if (String(url).endsWith('/device/code')) {
        return jsonResponse({
          device_code: 'device-code',
          user_code: 'ABCD-EFGH',
          verification_uri: 'https://www.google.com/device',
          expires_in: 1800,
          interval: 5,
        });
      }
      return jsonResponse({
        access_token: 'access-token',
        refresh_token: 'refresh-token',
        expires_in: 3600,
        token_type: 'Bearer',
        scope: 'https://www.googleapis.com/auth/youtube',
      });
    },
  });

  let prompt;
  const status = await oauth.login({ onCode: (value) => { prompt = value; } });

  assert.equal(prompt.userCode, 'ABCD-EFGH');
  assert.equal(status.status, 'configured');
  assert.equal(status.hasRefreshToken, true);
  assert.equal('accessToken' in status, false);
  assert.equal(store.get().refreshToken, 'refresh-token');
  assert.equal(requests[0].body.scope, 'https://www.googleapis.com/auth/youtube');
  assert.equal(requests[1].body.grant_type, 'urn:ietf:params:oauth:grant-type:device_code');
});

test('device login discovers the YouTube TV OAuth client when no override is configured', async () => {
  const store = memoryStore();
  const requests = [];
  const oauth = new GoogleOAuthClient({
    store,
    waitFunction: async () => {},
    fetchFunction: async (url, options = {}) => {
      requests.push({ url: String(url), body: requestBody(options.body) });
      if (String(url) === 'https://www.youtube.com/tv') {
        return textResponse('<script id="base-js" src="/s/tv.js"></script>');
      }
      if (String(url) === 'https://www.youtube.com/s/tv.js') {
        return textResponse('clientId:"tv-client-id",clientSecret:"tv-client-secret"');
      }
      if (String(url) === 'https://oauth2.googleapis.com/device/code') {
        return jsonResponse({
          device_code: 'device-code',
          user_code: 'ABCD-EFGH',
          verification_uri: 'https://www.google.com/device',
          expires_in: 1800,
          interval: 5,
        });
      }
      return jsonResponse({
        access_token: 'access-token',
        refresh_token: 'refresh-token',
        expires_in: 3600,
      });
    },
  });

  await oauth.login();

  assert.equal(oauth.status().clientMode, 'youtube-tv');
  assert.equal(requests[2].body.client_id, 'tv-client-id');
  assert.equal(requests[2].body.client_secret, 'tv-client-secret');
  assert.equal(requests[3].body.client_secret, 'tv-client-secret');
  assert.equal(requests[3].body.grant_type, 'http://oauth.net/grant_type/device/1.0');
  assert.equal(requests[3].body.code, 'device-code');
});

test('expired access tokens are refreshed and persisted', async () => {
  const store = memoryStore({
    accessToken: 'expired-token',
    refreshToken: 'refresh-token',
    expiresAt: '2026-06-20T00:00:00.000Z',
    tokenType: 'Bearer',
    scope: 'https://www.googleapis.com/auth/youtube.readonly',
  });
  const oauth = new GoogleOAuthClient({
    store,
    clientId: 'client-id',
    clientSecret: 'client-secret',
    now: () => Date.parse('2026-06-21T00:00:00.000Z'),
    fetchFunction: async (_url, options) => {
      assert.equal(Object.fromEntries(options.body).grant_type, 'refresh_token');
      return jsonResponse({ access_token: 'fresh-token', expires_in: 3600 });
    },
  });

  assert.equal(await oauth.accessToken(), 'fresh-token');
  assert.equal(store.get().accessToken, 'fresh-token');
  assert.equal(store.get().refreshToken, 'refresh-token');
});

test('revoked refresh tokens require a new device login', async () => {
  const store = memoryStore({
    refreshToken: 'revoked-token',
    expiresAt: '2026-06-20T00:00:00.000Z',
  });
  const oauth = new GoogleOAuthClient({
    store,
    clientId: 'client-id',
    clientSecret: 'client-secret',
    fetchFunction: async () => jsonResponse({
      error: 'invalid_grant',
      error_description: 'Token has been expired or revoked.',
    }, 400),
  });

  await assert.rejects(oauth.accessToken(), { code: 'oauth_reauthorization_required' });
  assert.equal(oauth.status().status, 'reauthorization_required');
});

test('oauth.json is restricted to the current user', async () => {
  const dataDir = await mkdtemp(join(tmpdir(), 'ytb-music-tv-oauth-'));
  try {
    await loadOAuthStore(dataDir);
    const file = await stat(join(dataDir, 'oauth.json'));
    assert.equal(file.mode & 0o777, 0o600);
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('running services reload credentials written by the login command', async () => {
  const dataDir = await mkdtemp(join(tmpdir(), 'ytb-music-tv-oauth-watch-'));
  const serverStore = await loadOAuthStore(dataDir, { watch: true });
  try {
    const loginStore = await loadOAuthStore(dataDir);
    await loginStore.patch({
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      expiresAt: '2026-06-21T01:00:00.000Z',
      updatedAt: '2026-06-21T00:00:00.000Z',
    });

    await waitFor(() => serverStore.get().refreshToken === 'refresh-token');
    assert.equal(serverStore.get().accessToken, 'access-token');
  } finally {
    serverStore.close();
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('shared OAuth login flow prints the Google URL and saved credential path', async () => {
  const lines = [];
  const oauth = {
    login: async ({ onCode }) => {
      await onCode({
        userCode: 'ABCD-EFGH',
        verificationUrl: 'https://www.google.com/device',
        verificationUrlComplete: 'https://www.google.com/device?user_code=ABCD-EFGH',
      });
    },
  };

  await runOAuthLoginFlow({
    oauth,
    dataDir: '/tmp/ytb-music-tv-test',
    logger: { log: (message) => lines.push(message) },
  });

  assert.match(lines[0], /https:\/\/www\.google\.com\/device\?user_code=ABCD-EFGH/);
  assert.match(lines[0], /Device code: ABCD-EFGH/);
  assert.equal(
    lines[1],
    'Google OAuth login completed. Credentials saved to /tmp/ytb-music-tv-test/oauth.json',
  );
});

const memoryStore = (initial = {}) => {
  let current = {
    accessToken: '',
    refreshToken: '',
    expiresAt: null,
    refreshTokenExpiresAt: null,
    tokenType: 'Bearer',
    scope: '',
    updatedAt: null,
    ...initial,
  };
  return {
    get: () => structuredClone(current),
    patch: async (patch) => {
      current = { ...current, ...structuredClone(patch) };
      return structuredClone(current);
    },
  };
};

const jsonResponse = (value, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { 'content-type': 'application/json' },
});

const textResponse = (value, status = 200) => new Response(value, { status });

const requestBody = (body) => {
  if (!body) return null;
  return typeof body === 'string' ? JSON.parse(body) : Object.fromEntries(body);
};

const waitFor = async (predicate) => {
  const deadline = Date.now() + 3000;
  while (!predicate() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(predicate(), true, 'timed out waiting for oauth.json reload');
};
