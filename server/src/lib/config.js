import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { randomInt, randomUUID } from 'node:crypto';
import { join } from 'node:path';

const defaultConfig = {
  security: {
    serverId: '',
    deviceCode: '',
    clients: [],
  },
  features: {
    adblock: {
      enabled: true,
      blockedHosts: [
        'doubleclick.net',
        'googleads.g.doubleclick.net',
        'googlesyndication.com',
        'adservice.google.com',
        'pagead2.googlesyndication.com',
      ],
      blockedPathPatterns: [
        '/pagead/',
        '/ptracking',
        '/api/stats/ads',
        '/pcs/activeview',
      ],
    },
    skipDislikedSongs: {
      enabled: true,
    },
  },
  playback: {
    selectedLibrary: null,
    preferVideo: true,
    defaultQuality: 'best',
    streamMode: 'proxy',
  },
  network: {
    proxy: {
      enabled: false,
      url: '',
      noProxy: [
        'localhost',
        '127.0.0.1',
        '::1',
      ],
    },
  },
  youtube: {
    accountIndex: 0,
    visitorData: '',
    poToken: '',
    userAgent:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.6723.152 Safari/537.36',
  },
};

export const loadConfig = async (dataDir) => {
  await mkdir(dataDir, { recursive: true });
  const configPath = join(dataDir, 'config.json');

  let current = structuredClone(defaultConfig);
  try {
    const raw = await readFile(configPath, 'utf8');
    current = mergeConfig(current, JSON.parse(raw));
    removeDeprecatedConfig(current);
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      throw error;
    }
    await writeFile(configPath, `${JSON.stringify(current, null, 2)}\n`);
  }

  let writeQueue = Promise.resolve();
  const save = async () => {
    const contents = `${JSON.stringify(current, null, 2)}\n`;
    const write = writeQueue.then(() => writeFile(configPath, contents));
    writeQueue = write.catch(() => {});
    await write;
  };

  if (ensureDeviceIdentity(current)) {
    await save();
  }

  return {
    get: () => structuredClone(current),
    patch: async (patch) => {
      current = mergeConfig(current, patch);
      removeDeprecatedConfig(current);
      ensureDeviceIdentity(current);
      await save();
      return structuredClone(current);
    },
    replace: async (next) => {
      current = mergeConfig(defaultConfig, next);
      removeDeprecatedConfig(current);
      ensureDeviceIdentity(current);
      await save();
      return structuredClone(current);
    },
  };
};

const mergeConfig = (base, patch) => {
  if (!isPlainObject(base) || !isPlainObject(patch)) {
    return structuredClone(patch ?? base);
  }

  const output = structuredClone(base);
  for (const [key, value] of Object.entries(patch)) {
    if (isPlainObject(value) && isPlainObject(output[key])) {
      output[key] = mergeConfig(output[key], value);
    } else {
      output[key] = structuredClone(value);
    }
  }

  return output;
};

const isPlainObject = (value) =>
  Boolean(value) &&
  typeof value === 'object' &&
  !Array.isArray(value) &&
  Object.getPrototypeOf(value) === Object.prototype;

const removeDeprecatedConfig = (config) => {
  delete config.auth;
  delete config.features?.syncedLyrics;
  delete config.security?.enabled;
};

const ensureDeviceIdentity = (config) => {
  let changed = false;
  config.security ??= {};

  if (!config.security.serverId) {
    config.security.serverId = randomUUID();
    changed = true;
  }

  const legacyCode = String(config.security.pairingCode ?? '');
  const currentCode = String(config.security.deviceCode ?? legacyCode);
  if (!/^\d{6}$/.test(currentCode)) {
    config.security.deviceCode = String(randomInt(0, 1_000_000)).padStart(6, '0');
    changed = true;
  } else if (config.security.deviceCode !== currentCode) {
    config.security.deviceCode = currentCode;
    changed = true;
  }

  if ('pairingCode' in config.security) {
    delete config.security.pairingCode;
    changed = true;
  }

  config.security.clients ??= [];
  return changed;
};
