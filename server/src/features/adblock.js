export const isBlockedUrl = (input, adblockConfig) => {
  if (!adblockConfig?.enabled) {
    return false;
  }

  let url;
  try {
    url = new URL(input);
  } catch {
    return true;
  }

  const hostname = url.hostname.toLowerCase();
  const hostBlocked = (adblockConfig.blockedHosts ?? []).some((blockedHost) => {
    const normalized = String(blockedHost).toLowerCase();
    return hostname === normalized || hostname.endsWith(`.${normalized}`);
  });
  if (hostBlocked) return true;

  return (adblockConfig.blockedPathPatterns ?? []).some((pattern) =>
    url.pathname.toLowerCase().includes(String(pattern).toLowerCase()),
  );
};

export const proxyUrl = async ({
  req,
  res,
  url,
  config,
  onUpstreamFailure = null,
  fetchFunction = globalThis.fetch,
}) => {
  if (isBlockedUrl(url, config.features.adblock)) {
    res.writeHead(403, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: 'blocked_by_adblock', url }));
    return;
  }

  const headers = {};
  if (req.headers.range) {
    headers.range = req.headers.range;
  }
  const upstream = await fetchFunction(url, {
    method: 'GET',
    headers,
    redirect: 'follow',
  });
  if (!upstream.ok) {
    let hostname = 'unknown-host';
    try {
      hostname = new URL(url).hostname;
    } catch {
      // Keep the diagnostic free of the signed media URL.
    }
    console.warn(`media proxy upstream failed: HTTP ${upstream.status} from ${hostname}`);

    const retryUrl = await onUpstreamFailure?.({
      status: upstream.status,
      url,
      hostname,
    });
    if (retryUrl) {
      await upstream.body?.cancel();
      return await proxyUrl({
        req,
        res,
        url: retryUrl,
        config,
        onUpstreamFailure,
        fetchFunction,
      });
    }
  }
  const responseHeaders = {};
  for (const [key, value] of upstream.headers.entries()) {
    if (hopByHopHeaders.has(key.toLowerCase())) {
      continue;
    }
    responseHeaders[key] = value;
  }

  responseHeaders['access-control-allow-origin'] = '*';
  res.writeHead(upstream.status, responseHeaders);

  if (req.method === 'HEAD') {
    await upstream.body?.cancel();
    res.end();
    return;
  }

  if (!upstream.body) {
    res.end();
    return;
  }

  for await (const chunk of upstream.body) {
    res.write(chunk);
  }
  res.end();
};

const hopByHopHeaders = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
]);
