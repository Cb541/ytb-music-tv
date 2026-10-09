#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
compiler="${SWIFTC:-swiftc}"
"$compiler" "$script_dir/Sources/YTBMusicTVClient/Models.swift" \
  "$script_dir/Sources/YTBMusicTVClient/MusicLyrics.swift" \
  "$script_dir/Sources/YTBMusicTVClient/MusicLookup.swift" \
  "$script_dir/Sources/YTBMusicTVClient/MusicStillCover.swift" \
  "$script_dir/Sources/YTBMusicTVClient/MusicBackdropState.swift" \
  "$script_dir/Tests/PlaybackAndLyricsTests.swift" -o "$build_dir/test-models"
"$build_dir/test-models"
