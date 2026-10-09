#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_dir="$(dirname "${test_dir}")"
test_build_dir="${BUILD_DIR:-${test_dir}/build}"
mkdir -p "${test_build_dir}"
staging_dir="$(mktemp -d "${test_build_dir}/staging.XXXXXX")"
trap 'rm -rf "${staging_dir}"' EXIT
mkdir -p "${staging_dir}/Sources/YTBMusicTVClient"
cp "${test_dir}/Sources/"*.swift "${staging_dir}/Sources/YTBMusicTVClient/"
cp -R "${client_dir}/Assets.xcassets" "${staging_dir}/Assets.xcassets"
cp "${client_dir}/build-ipa.sh" "${staging_dir}/build-ipa.sh"

# Reuse the established tvOS packager without changing the production target.
python3 - "${staging_dir}/build-ipa.sh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
marker = '  <key>UIApplicationSupportsIndirectInputEvents</key>'
assert text.count(marker) == 1
text = text.replace(marker, '''  <key>NSAppleMusicUsageDescription</key>
  <string>Connect to your Apple Music account to test full-track MusicKit playback and its active audio format.</string>
''' + marker)
p.write_text(text)
PY

export PRODUCT_NAME="MusicKitAtmosTest"
export DISPLAY_NAME="MusicKit Atmos Test"
export BUNDLE_ID="${BUNDLE_ID:-com.cb541.ytbmusickit.atmostest}"
export BUILD_DIR="${test_build_dir}"
export OUTPUT_IPA="${OUTPUT_IPA:-${test_build_dir}/MusicKit-Atmos-Test.ipa}"
export TVOS_DEPLOYMENT_TARGET="17.0"
bash "${staging_dir}/build-ipa.sh"
