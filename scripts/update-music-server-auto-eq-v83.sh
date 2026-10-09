#!/usr/bin/env bash
set -euo pipefail
# Installs song-adaptive Auto EQ plus Balanced, Immersive and Maximum Spatial Audio modes.
# Keeps existing OAuth, preferences, cookies, playlists and server data.
revision=1dd5b94fd5fc517dec69c51a46665813c78f10d9
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
for file in src/features/spatial-stream.js src/features/auto-eq.js src/lib/router.js Dockerfile; do
  mkdir -p "$staging/$(dirname "$file")"
  curl --fail --location --silent --show-error --max-time 35 \
    "$repo/server/$file" -o "$staging/$file"
done
backup=$(mktemp -d "$HOME/Downloads/YTBMusicTV-server-backup-auto-eq.XXXXXX")
mkdir -p "$backup/src/features" "$backup/src/lib"
cp "$project_dir/server/src/lib/router.js" "$backup/src/lib/"
cp "$project_dir/server/Dockerfile" "$backup/"
for file in spatial-stream.js auto-eq.js; do
  if [[ -f "$project_dir/server/src/features/$file" ]]; then
    cp "$project_dir/server/src/features/$file" "$backup/src/features/"
  fi
done
echo "Existing server files backed up to: $backup"
cp "$staging/src/lib/router.js" "$project_dir/server/src/lib/router.js"
cp "$staging/src/features/spatial-stream.js" "$project_dir/server/src/features/spatial-stream.js"
cp "$staging/src/features/auto-eq.js" "$project_dir/server/src/features/auto-eq.js"
cp "$staging/Dockerfile" "$project_dir/server/Dockerfile"
cd "$project_dir"
export YTB_MUSIC_TV_UID=${YTB_MUSIC_TV_UID:-$(id -u)}
export YTB_MUSIC_TV_GID=${YTB_MUSIC_TV_GID:-$(id -g)}
docker compose up -d --build ytb-music-tv-server
docker compose exec -T ytb-music-tv-server sh -lc \
  'command -v ffmpeg && node --input-type=module -e "import(\"./src/features/spatial-stream.js\").then(() => console.log(\"Auto EQ and Spatial Audio profiles installed\"))"'
echo "Server update complete. Install the matching tvOS Auto EQ IPA."
