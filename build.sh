#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/MacMonitorPreview.app"
[[ "$(uname -m)" == arm64 ]] || { echo "当前发布版仅支持 Apple Silicon。" >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$ROOT/build/module-cache"
MACMON_BINARY="$("$ROOT/fetch-macmon.sh")"
# 先写新文件再替换，避免修改运行中程序已经映射的可执行文件。
NEXT_BINARY="$ROOT/build/MacMonitorPreview.next"
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT"/Sources/*.swift -framework AppKit -framework IOKit \
  -o "$NEXT_BINARY"
mv -f "$NEXT_BINARY" "$APP/Contents/MacOS/MacMonitorPreview"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$MACMON_BINARY" "$APP/Contents/Helpers/macmon"
chmod 755 "$APP/Contents/Helpers/macmon"
cp "$ROOT/ThirdParty/macmon-LICENSE.txt" "$APP/Contents/Resources/macmon-LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$APP/Contents/Helpers/macmon" >/dev/null
/usr/bin/codesign --force --sign - "$APP" >/dev/null
echo "$APP"
