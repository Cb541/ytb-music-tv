#!/usr/bin/env bash
set -euo pipefail
# Prefer the high-quality Music session before TV playback. Keep local data/configuration.
revision=62d0bc4feb4027bee348bdacd6fc15af3fcb5ade
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
for file in services/youtube-service.js; do
  mkdir -p "$staging/$(dirname "$file")"
  curl --fail --location --silent --show-error --max-time 30 \
    "https://raw.githubusercontent.com/Cb541/ytb-music-tv/$revision/server/src/$file" -o "$staging/$file"
done
backup=$(mktemp -d "$HOME/Downloads/YTBMusicTV-server-backup-v72.XXXXXX")
cp -a "$project_dir/server/src" "$backup/"
echo "Original server files saved to: $backup"
for file in services/youtube-service.js; do
  cp "$staging/$file" "$project_dir/server/src/$file"
done
cd "$project_dir"
export YTB_MUSIC_TV_UID=${YTB_MUSIC_TV_UID:-$(id -u)}
export YTB_MUSIC_TV_GID=${YTB_MUSIC_TV_GID:-$(id -g)}
docker compose up -d --build ytb-music-tv-server
docker compose ps ytb-music-tv-server
echo 'Server updated. Keep your v71 IPA. High-quality Music audio now bypasses the TV lookup.'
