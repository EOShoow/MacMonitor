#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="0.7.2"
EXPECTED="c79fdc7ab02b456b897dcc3ea041678420d7a1d5bd669aaac36fda3885572ad6"
VENDOR="$ROOT/build/vendor/macmon-$VERSION"
ARCHIVE="$VENDOR/macmon-v$VERSION.tar.gz"
mkdir -p "$VENDOR"
if [[ ! -f "$ARCHIVE" ]]; then
  /usr/bin/curl --fail --silent --show-error --location --retry 2 \
    --connect-timeout 15 --max-time 60 \
    "https://github.com/vladkens/macmon/releases/download/v$VERSION/macmon-v$VERSION.tar.gz" \
    -o "$ARCHIVE.next"
  mv "$ARCHIVE.next" "$ARCHIVE"
fi
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "macmon 官方归档的校验值不符，停止构建。" >&2; exit 1; }
mkdir -p "$VENDOR/extracted"
/usr/bin/tar -xzf "$ARCHIVE" -C "$VENDOR/extracted"
[[ "$("$VENDOR/extracted/macmon" --version)" == "macmon $VERSION" ]]
/usr/bin/cmp -s "$VENDOR/extracted/LICENSE" "$ROOT/ThirdParty/macmon-LICENSE.txt"
echo "$VENDOR/extracted/macmon"
