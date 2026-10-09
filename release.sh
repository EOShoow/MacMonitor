#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"
APP="$ROOT/build/MacMonitorPreview.app"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
OUT="$ROOT/build/releases/$VERSION"
STAGE="$OUT/MacMonitor"
mkdir -p "$STAGE"
[[ ! -e "$STAGE/MacMonitor.app" ]] || { echo "此版本已打包，请使用新的干净输出目录。" >&2; exit 1; }
/usr/bin/ditto "$APP" "$STAGE/MacMonitor.app"
/usr/bin/codesign --verify --deep --strict "$STAGE/MacMonitor.app"
cp "$ROOT/INSTALL.md" "$STAGE/安装说明.md"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/THIRD_PARTY_NOTICES.md"
# 使用已验证的安装器；发布包直接安装已签名 App，无需在用户机器编译。
/usr/bin/sed -e 's|BUILT_APP="$ROOT/build/MacMonitorPreview.app"|BUILT_APP="$ROOT/MacMonitor.app"|' \
  -e '\|^"$ROOT/build.sh"$|d' "$ROOT/install.sh" > "$STAGE/安装并启用自启动.command"
chmod 755 "$STAGE/安装并启用自启动.command"
ln -s /Applications "$STAGE/Applications"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUT/MacMonitor-$VERSION-arm64.zip"
/usr/bin/hdiutil create -volname "MacMonitor $VERSION" -srcfolder "$STAGE" -format UDZO "$OUT/MacMonitor-$VERSION-arm64.dmg"
(
  cd "$OUT"
  /usr/bin/shasum -a 256 "MacMonitor-$VERSION-arm64.dmg" "MacMonitor-$VERSION-arm64.zip" > SHA256SUMS.txt
)
cp "$ROOT/CHANGELOG.md" "$OUT/RELEASE_NOTES.md"
echo "$OUT"
