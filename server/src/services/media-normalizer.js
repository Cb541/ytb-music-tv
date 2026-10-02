export const normalizeMediaNode = (node, fallback = {}) => {
  if (!node || typeof node !== 'object') {
    return null;
  }

  const itemType = node.item_type ?? fallback.itemType ?? 'unknown';
  const browsable = ['playlist', 'album', 'artist'].includes(itemType);
  const videoId = !browsable && node.id && isLikelyVideoId(node.id) ? node.id : undefined;
  const title = textOf(node.title) || node.name || fallback.title || 'Untitled';
  const artists = node.artists ?? (node.author ? [node.author] : node.authors ?? []);
  const artist = artists.map((entry) => entry?.name).filter(Boolean).join(', ');
  const album = node.album?.name ?? fallback.album ?? null;
  const durationMs = node.duration?.seconds ? node.duration.seconds * 1000 : 0;
  const artworkUrl = bestThumbnailUrl(node.thumbnails ?? node.thumbnail);
  const endpointBrowse = endpointBrowseId(node.endpoint);
  const endpointPlaylist = endpointPlaylistId(node.endpoint);
  const nodeBrowseId = node.id && (browsable || !isLikelyVideoId(node.id)) ? node.id : null;

  const id =
    videoId ??
    node.id ??
    endpointId(node.endpoint) ??
    `${itemType}:${title}:${artist || album || ''}`;

  return {
    id,
    videoId: videoId ?? null,
    browseId: endpointBrowse ?? nodeBrowseId,
    playlistId: endpointPlaylist ?? (itemType === 'playlist' ? nodeBrowseId : null),
    type: itemType,
    title: String(title),
    artist: artist || fallback.artist || '',
    album,
    artistBrowseId: artists.find((entry) => entry?.channel_id || entry?.id)?.channel_id ?? artists.find((entry) => entry?.id)?.id ?? null,
    albumBrowseId: node.album?.id ?? endpointBrowseId(node.album?.endpoint),
    durationMs,
    artworkUrl,
    streamUrl: null,
    sourceUrl: videoId ? `https://music.youtube.com/watch?v=${videoId}` : null,
    likeStatus: 'INDIFFERENT',
    tags: artists.map((entry) => entry?.name).filter(Boolean),
  };
};

export const normalizeTrackInfo = (info) => {
  const basic = info?.basic_info ?? {};
  const overlay = info?.player_overlays?.browser_media_session;
  const album = typeof overlay?.album?.text === 'string' ? overlay.album.text : null;

  return {
    id: basic.id,
    videoId: basic.id ?? null,
    browseId: null,
    playlistId: null,
    type: 'song',
    title: basic.title ?? 'Untitled',
    artist: basic.author ?? '',
    album,
    durationMs: (basic.duration ?? 0) * 1000,
    artworkUrl: bestThumbnailUrl(basic.thumbnail),
    streamUrl: null,
    sourceUrl: basic.url_canonical ?? (basic.id ? `https://music.youtube.com/watch?v=${basic.id}` : null),
    likeStatus: basic.is_disliked ? 'DISLIKE' : basic.is_liked ? 'LIKE' : 'INDIFFERENT',
    tags: basic.tags ?? basic.keywords ?? [],
  };
};

export const normalizeSection = (section, index = 0) => {
  const title = textOf(section?.title) || textOf(section?.header?.title) || `Section ${index + 1}`;
  const contents = Array.from(section?.contents ?? [])
    .map((item) => normalizeMediaNode(item, { itemType: section?.type }))
    .filter(Boolean);

  return {
    id: slugify(title) || `section-${index}`,
    title,
    items: contents,
  };
};

export const normalizeSearch = (search) => {
  const shelves = [
    search.songs,
    search.videos,
    search.albums,
    search.artists,
    search.playlists,
    ...(Array.from(search.contents ?? []).filter(
      (item) => ![search.songs, search.videos, search.albums, search.artists, search.playlists].includes(item),
    )),
  ].filter(Boolean);

  return {
    filters: search.filters ?? [],
    sections: shelves.map(normalizeSection),
  };
};

const textOf = (value) => {
  if (!value) return '';
  if (typeof value === 'string') return value;
  if (typeof value.text === 'string') return value.text;
  if (typeof value.toString === 'function') return value.toString();
  return '';
};

const bestThumbnailUrl = (thumbnails) => {
  const list = Array.isArray(thumbnails)
    ? thumbnails
    : thumbnails?.contents ?? thumbnails?.thumbnails ?? [];
  const best = [...list].sort((left, right) => {
    const leftSize = (left.width ?? 0) * (left.height ?? 0);
    const rightSize = (right.width ?? 0) * (right.height ?? 0);
    return rightSize - leftSize;
  })[0];
  return best?.url ?? null;
};

const endpointId = (endpoint) =>
  endpoint?.payload?.watchEndpoint?.videoId ??
  endpoint?.payload?.watchEndpoint?.playlistId ??
  endpoint?.payload?.browseEndpoint?.browseId ??
  null;

const endpointBrowseId = (endpoint) => endpoint?.payload?.browseEndpoint?.browseId ?? null;
const endpointPlaylistId = (endpoint) =>
  endpoint?.payload?.watchEndpoint?.playlistId ?? endpoint?.payload?.browseEndpoint?.browseId ?? null;

const isLikelyVideoId = (value) => /^[a-zA-Z0-9_-]{11}$/.test(String(value));

const slugify = (value) =>
  String(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/(^-|-$)/g, '');
