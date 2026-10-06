#!/usr/bin/env bash
set -euo pipefail
# Prefer the high-quality Music session before TV playback. Keep local data/configuration.
revision=4b0e03639aff91a89d81e4d0d899d024f52437e0
container=$(docker ps -aq --filter label=com.docker.compose.service=ytb-music-tv-server | head -n 1)
if [[ -z "$container" ]]; then
  echo 'Could not find the music server container. Start it first.' >&2
  exit 1
fi
project_dir=${1:-$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container")}
if [[ ! -f "$project_dir/docker-compose.yml" || ! -d "$project_dir/server/src" ]]; then
  echo 'Could not find server sources. Pass your ytb-music-tv folder as the first argument.' >&2
  exit 1
fi
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
for file in lib/router.js services/youtube-service.js; do
  mkdir -p "$staging/$(dirname "$file")"
  curl --fail --location --silent --show-error --max-time 30 \
    "https://raw.githubusercontent.com/Cb541/ytb-music-tv/$revision/server/src/$file" -o "$staging/$file"
done
backup=$(mktemp -d "$HOME/Downloads/YTBMusicTV-server-backup-v74.XXXXXX")
cp -a "$project_dir/server/src" "$backup/"
echo "Original server files saved to: $backup"
for file in lib/router.js services/youtube-service.js; do
  cp "$staging/$file" "$project_dir/server/src/$file"
done
cd "$project_dir"
export YTB_MUSIC_TV_UID=${YTB_MUSIC_TV_UID:-$(id -u)}
export YTB_MUSIC_TV_GID=${YTB_MUSIC_TV_GID:-$(id -g)}
docker compose up -d --build ytb-music-tv-server
docker compose ps ytb-music-tv-server
docker compose exec -T ytb-music-tv-server node --input-type=module <<'NODE'
const port = process.env.YTB_MUSIC_TV_PORT ?? '4174';
for (let attempt = 0; attempt < 20; attempt++) {
  try {
    // GET must return 405 for this POST route, rather than 404 for a missing route.
    const response = await fetch(`http://127.0.0.1:${port}/api/resolve-song`, { signal: AbortSignal.timeout(1000) });
    if (response.status === 405) {
      console.log('Official-song playback route verified.');
      process.exit(0);
    }
    if (response.status === 404) throw new Error('Playback route is still missing');
  } catch (error) {
    if (attempt === 19) {
      console.error('Playback route verification failed:', error.message);
      process.exit(1);
    }
  }
  await new Promise(resolve => setTimeout(resolve, 500));
}
console.error('Playback route verification failed.');
process.exit(1);
NODE
echo 'Server updated. Install the v74 IPA for recording-specific lyrics and corrected control navigation.' 
