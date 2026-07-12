import { createServer } from 'node:http';
import { hostname } from 'node:os';
import { join } from 'node:path';

import { loadConfig } from './lib/config.js';
import { startDiscoveryServer } from './lib/discovery.js';
import { startOAuthLoginFlow } from './lib/oauth-login-flow.js';
import { loadOAuthStore } from './lib/oauth-store.js';
import { createProxyFetch, effectiveProxyConfig, redactProxyUrl } from './lib/proxy-fetch.js';
import { createApiRouter } from './lib/router.js';
import { loadSessionStore } from './lib/session-store.js';
import { GoogleOAuthClient, oauthConfigFromEnv } from './services/google-oauth.js';
import { YouTubeMusicService } from './services/youtube-service.js';
import { YouTubeTvService } from './services/youtube-tv-service.js';

const host = process.env.YTB_MUSIC_TV_HOST ?? '127.0.0.1';
const port = Number.parseInt(process.env.YTB_MUSIC_TV_PORT ?? '4174', 10);
const discoveryPort = Number.parseInt(process.env.YTB_MUSIC_TV_DISCOVERY_PORT ?? '4175', 10);
const dataDir = process.env.YTB_MUSIC_TV_DATA_DIR ?? new URL('../data', import.meta.url).pathname;
const serverName = process.env.YTB_MUSIC_TV_SERVER_NAME ?? hostname();

const configStore = await loadConfig(dataDir);
const fetchFunction = createProxyFetch({ configStore });
const sessionStore = await loadSessionStore(dataDir);
const oauthStore = await loadOAuthStore(dataDir, { watch: true });
const oauth = new GoogleOAuthClient({
  store: oauthStore,
  fetchFunction,
  ...oauthConfigFromEnv(),
});
const youtubeTvService = new YouTubeTvService({
  oauth,
  fetchFunction,
  maxItems: Number.parseInt(process.env.YTB_MUSIC_TV_LIBRARY_MAX_ITEMS ?? '5000', 10),
});
const youtubeService = new YouTubeMusicService({
  configStore,
  sessionStore,
  oauthLibraryService: youtubeTvService,
  fetchFunction,
});
const router = createApiRouter({
  configStore,
  youtubeService,
  serverName,
  fetchFunction,
});
const config = configStore.get();

startDiscoveryServer({
  discoveryPort,
  servicePort: port,
  serverId: config.security.serverId,
  serverName,
});

const server = createServer((req, res) => {
  router(req, res).catch((error) => {
    console.error(error);
    if (!res.headersSent) {
      res.writeHead(500, { 'content-type': 'application/json; charset=utf-8' });
    }
    res.end(JSON.stringify({ error: 'internal_error', message: String(error?.message ?? error) }));
  });
});

server.listen(port, host, () => {
  console.log(`YTB Music TV server listening on http://${host}:${port}`);
  console.log(`YTB Music TV device code: ${config.security.deviceCode}`);
  const proxyConfig = effectiveProxyConfig(config.network?.proxy);
  if (proxyConfig.enabled) {
    console.log(`YTB Music TV outbound proxy enabled: ${redactProxyUrl(proxyConfig.url)}`);
  }

  const authStatus = youtubeService.authStatus();
  if (!authStatus.hasOAuthToken) {
    console.warn([
      'Google OAuth is not configured; starting device login for personal Library access.',
      `OAuth credentials are stored in ${join(dataDir, 'oauth.json')}.`,
      'Public search, recommendations, and playback remain available without a Cookie.',
    ].join('\n'));
    startOAuthLoginFlow({ oauth, dataDir });
  } else if (authStatus.status !== 'configured') {
    console.warn([
      `Google OAuth status is ${authStatus.status}; personal Library content may be unavailable.`,
      'Run `pnpm oauth:login` or execute `node src/cli/oauth-login.js` in the container to replace the current token.',
      `OAuth credentials are stored in ${join(dataDir, 'oauth.json')}.`,
    ].join('\n'));
  }
});
