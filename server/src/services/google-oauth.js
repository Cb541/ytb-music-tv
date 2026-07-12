const DEVICE_CODE_URL = 'https://oauth2.googleapis.com/device/code';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const DEVICE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:device_code';
const YOUTUBE_DEVICE_GRANT_TYPE = 'http://oauth.net/grant_type/device/1.0';
const REFRESH_GRANT_TYPE = 'refresh_token';
const YOUTUBE_READONLY_SCOPE = 'https://www.googleapis.com/auth/youtube.readonly';
const DEFAULT_SCOPE = 'https://www.googleapis.com/auth/youtube';
const YOUTUBE_TV_SCOPE = DEFAULT_SCOPE;
const REFRESH_MARGIN_MS = 60_000;
const YOUTUBE_TV_URL = 'https://www.youtube.com/tv';
const YOUTUBE_TV_USER_AGENT = 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version';

export class GoogleOAuthClient {
  #store;
  #clientId;
  #clientSecret;
  #fetch;
  #wait;
  #now;
  #refreshPromise;
  #clientCredentialsPromise;
  #lastError = null;
  #failedTokenUpdatedAt = null;

  constructor({
    store,
    clientId,
    clientSecret,
    fetchFunction = globalThis.fetch,
    waitFunction = wait,
    now = Date.now,
  }) {
    this.#store = store;
    this.#clientId = String(clientId ?? '').trim();
    this.#clientSecret = String(clientSecret ?? '').trim();
    this.#fetch = fetchFunction;
    this.#wait = waitFunction;
    this.#now = now;
  }

  status() {
    const token = this.#store.get();
    this.#acceptExternalTokenUpdate(token);
    const hasCompleteOverride = Boolean(this.#clientId && this.#clientSecret);
    const hasPartialOverride = Boolean(this.#clientId || this.#clientSecret) && !hasCompleteOverride;
    const credentialsConfigured = !hasPartialOverride;
    const hasRefreshToken = Boolean(token.refreshToken);
    let status = 'not_configured';

    if (this.#lastError?.code === 'oauth_reauthorization_required') {
      status = 'reauthorization_required';
    } else if (hasRefreshToken && !hasPartialOverride) {
      status = 'configured';
    } else if (hasPartialOverride) {
      status = 'misconfigured';
    }

    return {
      status,
      credentialsConfigured,
      clientMode: hasCompleteOverride ? 'environment' : 'youtube-tv',
      hasRefreshToken,
      scope: token.scope || DEFAULT_SCOPE,
      expiresAt: token.expiresAt,
      updatedAt: token.updatedAt,
      error: this.#lastError?.message ?? null,
    };
  }

  async login({ scope = null, onCode = () => {} } = {}) {
    const credentials = await this.#clientCredentials();
    const flow = oauthFlow(credentials, scope);
    const device = await this.#post(flow.deviceCodeUrl, {
      client_id: credentials.clientId,
      ...(flow.mode === 'youtube-tv' ? { client_secret: credentials.clientSecret } : {}),
      scope: flow.scope,
    }, flow.encoding);

    const verificationUrl = device.verification_uri ?? device.verification_url;
    if (!device.device_code || !device.user_code || !verificationUrl) {
      throw oauthError('Google returned an incomplete device authorization response.', 'oauth_invalid_response');
    }

    await onCode({
      userCode: device.user_code,
      verificationUrl,
      verificationUrlComplete: device.verification_uri_complete ?? null,
      expiresIn: Number(device.expires_in ?? 1800),
    });

    const token = await this.#pollForToken({
      credentials,
      flow,
      deviceCode: device.device_code,
      intervalSeconds: Number(device.interval ?? 5),
      expiresInSeconds: Number(device.expires_in ?? 1800),
    });
    const now = this.#now();
    await this.#store.patch({
      accessToken: token.access_token,
      refreshToken: token.refresh_token,
      expiresAt: new Date(now + Number(token.expires_in ?? 3600) * 1000).toISOString(),
      refreshTokenExpiresAt: token.refresh_token_expires_in
        ? new Date(now + Number(token.refresh_token_expires_in) * 1000).toISOString()
        : null,
      tokenType: token.token_type ?? 'Bearer',
      scope: token.scope ?? flow.scope,
      updatedAt: new Date(now).toISOString(),
    });
    this.#lastError = null;
    this.#failedTokenUpdatedAt = null;
    return this.status();
  }

  async accessToken({ forceRefresh = false } = {}) {
    const token = this.#store.get();
    this.#acceptExternalTokenUpdate(token);
    if (!token.refreshToken) {
      throw oauthError('Google OAuth login is required.', 'oauth_required');
    }
    await this.#clientCredentials();

    const expiresAt = Date.parse(token.expiresAt ?? '');
    if (!forceRefresh && token.accessToken && Number.isFinite(expiresAt) &&
        expiresAt > this.#now() + REFRESH_MARGIN_MS) {
      return token.accessToken;
    }

    if (!this.#refreshPromise) {
      this.#refreshPromise = this.#refreshAccessToken().finally(() => {
        this.#refreshPromise = null;
      });
    }
    return await this.#refreshPromise;
  }

  async #refreshAccessToken() {
    const current = this.#store.get();
    const credentials = await this.#clientCredentials();
    const flow = oauthFlow(credentials, current.scope || null);
    let token;
    try {
      token = await this.#post(flow.tokenUrl, {
        client_id: credentials.clientId,
        client_secret: credentials.clientSecret,
        refresh_token: current.refreshToken,
        grant_type: REFRESH_GRANT_TYPE,
      }, flow.encoding);
    } catch (error) {
      this.#failedTokenUpdatedAt = current.updatedAt;
      if (error.code === 'invalid_grant') {
        this.#lastError = oauthError(
          'Google OAuth authorization expired or was revoked. Run the OAuth login command again.',
          'oauth_reauthorization_required',
        );
        throw this.#lastError;
      }
      this.#lastError = error;
      throw error;
    }

    const now = this.#now();
    const next = await this.#store.patch({
      accessToken: token.access_token,
      refreshToken: token.refresh_token ?? current.refreshToken,
      expiresAt: new Date(now + Number(token.expires_in ?? 3600) * 1000).toISOString(),
      tokenType: token.token_type ?? current.tokenType ?? 'Bearer',
      scope: token.scope ?? current.scope,
      updatedAt: new Date(now).toISOString(),
    });
    this.#lastError = null;
    this.#failedTokenUpdatedAt = null;
    return next.accessToken;
  }

  async #pollForToken({ credentials, flow, deviceCode, intervalSeconds, expiresInSeconds }) {
    const deadline = this.#now() + expiresInSeconds * 1000;
    let delaySeconds = Math.max(1, intervalSeconds);

    while (this.#now() < deadline) {
      await this.#wait(delaySeconds * 1000);
      try {
        const token = await this.#post(flow.tokenUrl, {
          client_id: credentials.clientId,
          client_secret: credentials.clientSecret,
          [flow.deviceCodeField]: deviceCode,
          grant_type: flow.deviceGrantType,
        }, flow.encoding);
        if (!token.access_token || !token.refresh_token) {
          throw oauthError('Google returned an incomplete OAuth token response.', 'oauth_invalid_response');
        }
        return token;
      } catch (error) {
        if (error.code === 'authorization_pending') continue;
        if (error.code === 'slow_down') {
          delaySeconds += 5;
          continue;
        }
        if (error.code === 'access_denied') {
          throw oauthError('Google OAuth access was denied.', 'oauth_access_denied');
        }
        if (error.code === 'expired_token') break;
        throw error;
      }
    }

    throw oauthError('Google OAuth device code expired. Run the login command again.', 'oauth_device_code_expired');
  }

  async #post(url, fields, encoding = 'form') {
    const response = await this.#fetch(url, {
      method: 'POST',
      headers: {
        'content-type': encoding === 'json'
          ? 'application/json'
          : 'application/x-www-form-urlencoded',
      },
      body: encoding === 'json' ? JSON.stringify(fields) : new URLSearchParams(fields),
    });
    const data = await response.json().catch(() => ({}));
    const errorCode = data.error ?? data.error_code;
    if (!response.ok || errorCode) {
      throw oauthError(
        data.error_description ?? `Google OAuth request failed with HTTP ${response.status}.`,
        errorCode ?? 'oauth_request_failed',
        response.status,
      );
    }
    return data;
  }

  async #clientCredentials() {
    if (this.#clientId || this.#clientSecret) {
      if (this.#clientId && this.#clientSecret) {
        return { clientId: this.#clientId, clientSecret: this.#clientSecret, mode: 'environment' };
      }
      throw oauthError(
        'Set both YTB_MUSIC_TV_OAUTH_CLIENT_ID and YTB_MUSIC_TV_OAUTH_CLIENT_SECRET, or neither.',
        'oauth_client_not_configured',
      );
    }

    if (!this.#clientCredentialsPromise) {
      this.#clientCredentialsPromise = this.#discoverYoutubeTvClient().catch((error) => {
        this.#clientCredentialsPromise = null;
        throw error;
      });
    }
    return await this.#clientCredentialsPromise;
  }

  async #discoverYoutubeTvClient() {
    const pageResponse = await this.#fetch(YOUTUBE_TV_URL, {
      headers: {
        'user-agent': YOUTUBE_TV_USER_AGENT,
        referer: YOUTUBE_TV_URL,
        'accept-language': 'en-US',
      },
    });
    if (!pageResponse.ok) {
      throw oauthError(
        `Unable to load the YouTube TV client page (HTTP ${pageResponse.status}).`,
        'oauth_tv_client_discovery_failed',
      );
    }

    const page = await pageResponse.text();
    const scriptPath = findTvScript(page);
    if (!scriptPath) {
      throw oauthError('Unable to find the YouTube TV client script.', 'oauth_tv_client_discovery_failed');
    }

    const scriptResponse = await this.#fetch(new URL(scriptPath, YOUTUBE_TV_URL), {
      headers: { 'user-agent': YOUTUBE_TV_USER_AGENT },
    });
    if (!scriptResponse.ok) {
      throw oauthError(
        `Unable to load the YouTube TV client script (HTTP ${scriptResponse.status}).`,
        'oauth_tv_client_discovery_failed',
      );
    }

    const identity = (await scriptResponse.text())
      .match(/clientId:"(?<clientId>[^"]+)",[^\"]*?:"(?<clientSecret>[^"]+)"/);
    if (!identity?.groups?.clientId || !identity.groups.clientSecret) {
      throw oauthError('Unable to extract the YouTube TV OAuth client.', 'oauth_tv_client_discovery_failed');
    }

    return {
      clientId: identity.groups.clientId,
      clientSecret: identity.groups.clientSecret,
      mode: 'youtube-tv',
    };
  }

  #acceptExternalTokenUpdate(token) {
    if (this.#lastError && token.updatedAt !== this.#failedTokenUpdatedAt) {
      this.#lastError = null;
      this.#failedTokenUpdatedAt = null;
    }
  }
}

export const oauthConfigFromEnv = (env = process.env) => ({
  clientId: env.YTB_MUSIC_TV_OAUTH_CLIENT_ID ?? '',
  clientSecret: env.YTB_MUSIC_TV_OAUTH_CLIENT_SECRET ?? '',
});

const oauthError = (message, code, status = null) => {
  const error = new Error(message);
  error.code = code;
  error.status = status;
  return error;
};

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const oauthFlow = (credentials, requestedScope) => credentials.mode === 'youtube-tv'
  ? {
      mode: 'youtube-tv',
      deviceCodeUrl: DEVICE_CODE_URL,
      tokenUrl: TOKEN_URL,
      deviceGrantType: YOUTUBE_DEVICE_GRANT_TYPE,
      deviceCodeField: 'code',
      encoding: 'form',
      // The shared YouTube TV client rejects youtube.readonly with restricted_client.
      scope: requestedScope || YOUTUBE_TV_SCOPE,
    }
  : {
      mode: 'google',
      deviceCodeUrl: DEVICE_CODE_URL,
      tokenUrl: TOKEN_URL,
      deviceGrantType: DEVICE_GRANT_TYPE,
      deviceCodeField: 'device_code',
      encoding: 'form',
      scope: requestedScope || DEFAULT_SCOPE,
    };

const findTvScript = (page) => page.match(
  /<script\s+id=["']base-js["']\s+src=["']([^"']+)["'][^>]*><\/script>/i,
)?.[1] ?? page.match(
  /<script\s+src=["']([^"']+)["']\s+id=["']base-js["'][^>]*><\/script>/i,
)?.[1] ?? null;

export const GOOGLE_YOUTUBE_READONLY_SCOPE = YOUTUBE_READONLY_SCOPE;
