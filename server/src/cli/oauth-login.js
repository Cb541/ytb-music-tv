#!/usr/bin/env node

import { runOAuthLoginFlow } from '../lib/oauth-login-flow.js';
import { loadConfig } from '../lib/config.js';
import { loadOAuthStore } from '../lib/oauth-store.js';
import { createProxyFetch } from '../lib/proxy-fetch.js';
import {
  GoogleOAuthClient,
  oauthConfigFromEnv,
} from '../services/google-oauth.js';

const dataDir = process.env.YTB_MUSIC_TV_DATA_DIR ?? new URL('../../data', import.meta.url).pathname;
const configStore = await loadConfig(dataDir);
const fetchFunction = createProxyFetch({ configStore });
const store = await loadOAuthStore(dataDir);
const oauth = new GoogleOAuthClient({
  store,
  fetchFunction,
  ...oauthConfigFromEnv(),
});

try {
  await runOAuthLoginFlow({ oauth, dataDir });
} catch (error) {
  console.error(`Google OAuth login failed: ${error?.message ?? error}`);
  process.exitCode = 1;
}
