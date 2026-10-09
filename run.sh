#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.eoshow.mac-monitor-preview"
DOMAIN="gui/$(id -u)"
# 已安装时使用同一个启动项；手动退出后可重新启动，不再另开构建目录的副本。
if /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl kickstart "$DOMAIN/$LABEL"
  exit 0
fi
INSTALLED_APP="$HOME/Applications/MacMonitorPreview.app"
if [[ -x "$INSTALLED_APP/Contents/MacOS/MacMonitorPreview" ]]; then
  /usr/bin/open "$INSTALLED_APP"
  exit 0
fi
APP="$ROOT/build/MacMonitorPreview.app"
if [[ ! -x "$APP/Contents/MacOS/MacMonitorPreview" ]]; then
  "$ROOT/build.sh"
fi
# 尚未安装时直接试运行，不退出旧温度 App。
/usr/bin/open "$APP"
