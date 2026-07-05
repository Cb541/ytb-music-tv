import nodeFetch from 'node-fetch';
import { ProxyAgent } from 'proxy-agent';

const SUPPORTED_PROXY_PROTOCOLS = new Set([
  'http:',
  'https:',
  'socks:',
  'socks4:',
  'socks4a:',
  'socks5:',
  'socks5h:',
]);

export const createProxyFetch = ({
  configStore = null,
  env = process.env,
  fetchFunction = nodeFetch,
} = {}) => {
  const agents = new Map();

  return async (input, init = {}) => {
    const proxy = effectiveProxyConfig(configStore?.get().network?.proxy, env);
    const [fetchInput, fetchInit] = normalizeFetchArgs(input, init);
    if (!shouldProxyRequest(fetchInput, proxy)) {
      return await fetchFunction(fetchInput, fetchInit);
    }

    let agent = agents.get(proxy.url);
    if (!agent) {
      agent = new ProxyAgent(proxy.url);
      agents.set(proxy.url, agent);
    }

    return await fetchFunction(fetchInput, {
      ...fetchInit,
      agent: fetchInit.agent ?? agent,
    });
  };
};

export const effectiveProxyConfig = (config = {}, env = process.env) => {
  const envProxyUrl = stringValue(env.YTB_MUSIC_TV_PROXY_URL);
  const envNoProxy = splitNoProxy(env.YTB_MUSIC_TV_NO_PROXY);

  if (envProxyUrl) {
    return normalizeProxyConfig({
      enabled: true,
      url: envProxyUrl,
      noProxy: envNoProxy.length > 0 ? envNoProxy : config?.noProxy,
    });
  }

  return normalizeProxyConfig(config);
};

export const normalizeProxyConfig = (config = {}) => {
  const enabled = Boolean(config?.enabled);
  const url = stringValue(config?.url);
  const noProxy = normalizeNoProxy(config?.noProxy);

  if (!enabled) {
    return { enabled: false, url, noProxy };
  }
  validateProxyUrl(url);
  return { enabled: true, url, noProxy };
};

export const publicProxyConfig = (config = {}) => {
  let normalized;
  try {
    normalized = normalizeProxyConfig(config);
  } catch (error) {
    normalized = {
      enabled: Boolean(config?.enabled),
      url: stringValue(config?.url),
      noProxy: normalizeNoProxy(config?.noProxy),
      error: error.code ?? 'invalid_proxy_config',
    };
  }
  return {
    ...normalized,
    url: redactProxyUrl(normalized.url),
  };
};

export const proxyConfigPatch = (patch = {}) => {
  const proxy = patch?.proxy;
  if (!proxy || typeof proxy !== 'object' || Array.isArray(proxy)) {
    return {};
  }

  const next = {};
  if ('enabled' in proxy) next.enabled = Boolean(proxy.enabled);
  if ('url' in proxy) next.url = stringValue(proxy.url);
  if ('noProxy' in proxy) next.noProxy = normalizeNoProxy(proxy.noProxy);

  if ('url' in next && next.url) {
    validateProxyUrl(next.url);
  }

  return { proxy: next };
};

export const redactProxyUrl = (value) => {
  const url = stringValue(value);
  if (!url) return '';

  try {
    const parsed = new URL(url);
    if (parsed.password) parsed.password = '***';
    return parsed.toString();
  } catch {
    return '';
  }
};

const shouldProxyRequest = (input, proxy) => {
  if (!proxy.enabled || !proxy.url) return false;
  const requestUrl = requestUrlFromInput(input);
  if (!requestUrl) return false;

  let parsed;
  try {
    parsed = new URL(requestUrl);
  } catch {
    return false;
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return false;
  }

  return !matchesNoProxy(parsed, proxy.noProxy);
};

const normalizeFetchArgs = (input, init = {}) => {
  if (!isRequestLike(input)) {
    return [input, init];
  }

  const nextInit = {
    method: input.method,
    headers: input.headers,
    redirect: input.redirect,
    signal: input.signal,
    ...init,
  };
  if (init.body == null && input.body != null && input.method !== 'GET' && input.method !== 'HEAD') {
    nextInit.body = input.body;
  }

  return [input.url, nextInit];
};

const requestUrlFromInput = (input) => {
  if (typeof input === 'string') return input;
  if (input instanceof URL) return input.toString();
  if (isRequestLike(input)) return input.url;
  return '';
};

const isRequestLike = (value) =>
  Boolean(value) &&
  typeof value === 'object' &&
  typeof value.url === 'string' &&
  typeof value.method === 'string';

const matchesNoProxy = (url, noProxy) => {
  const hostname = normalizeHost(url.hostname);
  const port = url.port || (url.protocol === 'https:' ? '443' : '80');

  return noProxy.some((entry) => {
    const rule = String(entry ?? '').trim().toLowerCase();
    if (!rule) return false;
    if (rule === '*') return true;

    const [rawHostRule, portRule] = splitHostPort(rule);
    const hostRule = normalizeHost(rawHostRule);
    if (portRule && portRule !== port) return false;

    if (hostRule.startsWith('.')) {
      const suffix = hostRule.slice(1);
      return hostname === suffix || hostname.endsWith(hostRule);
    }

    return hostname === hostRule || hostname.endsWith(`.${hostRule}`);
  });
};

const splitHostPort = (value) => {
  if (value.startsWith('[')) {
    const match = value.match(/^\[(?<host>[^\]]+)\](?::(?<port>\d+))?$/);
    return [match?.groups?.host ?? value, match?.groups?.port ?? ''];
  }

  if (value.includes(':') && value.indexOf(':') !== value.lastIndexOf(':')) {
    return [value, ''];
  }

  const separator = value.lastIndexOf(':');
  if (separator > -1 && /^\d+$/.test(value.slice(separator + 1))) {
    return [value.slice(0, separator), value.slice(separator + 1)];
  }
  return [value, ''];
};

const normalizeNoProxy = (value) => {
  if (Array.isArray(value)) {
    return value.map(stringValue).filter(Boolean);
  }
  return splitNoProxy(value);
};

const splitNoProxy = (value) =>
  stringValue(value)
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean);

const validateProxyUrl = (value) => {
  const url = stringValue(value);
  if (!url) {
    throw proxyConfigError('Proxy URL is required when proxy is enabled.');
  }

  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    throw proxyConfigError('Proxy URL must be a valid URL.');
  }

  if (!SUPPORTED_PROXY_PROTOCOLS.has(parsed.protocol)) {
    throw proxyConfigError(
      'Proxy URL must use http, https, socks4, socks5, or socks5h.',
    );
  }
};

const proxyConfigError = (message) => {
  const error = new Error(message);
  error.code = 'invalid_proxy_config';
  error.status = 400;
  return error;
};

const stringValue = (value) => String(value ?? '').trim();

const normalizeHost = (value) =>
  String(value ?? '').trim().toLowerCase().replace(/^\[(.*)\]$/, '$1');
