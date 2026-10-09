#!/usr/bin/env bash
set -euo pipefail
# Adds FFmpeg-powered stereo widening to the existing Docker music server.
# Keeps existing OAuth, preferences, cookies, playlists and server data.
revision=43342b4ab4c037b2aeb9b1099e628c73828573b0
repo=https://raw.githubusercontent.com/Cb541/ytb-music-tv/$revision
container=$(docker ps -aq --filter label=com.docker.compose.service=ytb-music-tv-server | head -n 1)
if [[ -z "$container" ]]; then
  echo 'Music server container not found; start the current server first.' >&2
  exit 1
fi
project_dir=${1:-$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container")}
if [[ ! -f "$project_dir/docker-compose.yml" || ! -d "$project_dir/server/src/features" ]]; then
  echo 'Music server source folder not found; pass your project directory as the first argument.' >&2
  exit 1
fi
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
for file in src/features/spatial-stream.js src/lib/router.js Dockerfile; do
  mkdir -p "$staging/$(dirname "$file")"
  curl --fail --location --silent --show-error --max-time 35 \
    "$repo/server/$file" -o "$staging/$file"
done
backup=$(mktemp -d "$HOME/Downloads/YTBMusicTV-server-backup-spatial.XXXXXX")
mkdir -p "$backup/src/features" "$backup/src/lib"
cp "$project_dir/server/src/lib/router.js" "$backup/src/lib/"
cp "$project_dir/server/Dockerfile" "$backup/"
if [[ -f "$project_dir/server/src/features/spatial-stream.js" ]]; then
  cp "$project_dir/server/src/features/spatial-stream.js" "$backup/src/features/"
fi
echo "Existing server files backed up to: $backup"
cp "$staging/src/lib/router.js" "$project_dir/server/src/lib/router.js"
cp "$staging/src/features/spatial-stream.js" "$project_dir/server/src/features/spatial-stream.js"
cp "$staging/Dockerfile" "$project_dir/server/Dockerfile"
cd "$project_dir"
export YTB_MUSIC_TV_UID=${YTB_MUSIC_TV_UID:-$(id -u)}
export YTB_MUSIC_TV_GID=${YTB_MUSIC_TV_GID:-$(id -g)}
docker compose up -d --build ytb-music-tv-server
docker compose exec -T ytb-music-tv-server sh -lc \
  'command -v ffmpeg && node --input-type=module -e "import(\"./src/features/spatial-stream.js\").then(() => console.log(\"Stereo AAC/HLS server installed\"))"'
echo "Server update complete. Install the matching tvOS Spatial HLS IPA."
