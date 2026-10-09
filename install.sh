#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILT_APP="$ROOT/build/MacMonitorPreview.app"
APP="$HOME/Applications/MacMonitorPreview.app"
LABEL="com.eoshow.mac-monitor-preview"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.local/state/mac-monitor-preview"
DOMAIN="gui/$(id -u)"

"$ROOT/build.sh"
/usr/bin/codesign --verify --strict "$BUILT_APP"
# 只接管本测试版自己的 App 和启动项，避免覆盖同名的其他程序。
if [[ -e "$APP" ]]; then
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" == "$LABEL" ]]
fi
if [[ -e "$PLIST" ]]; then
  [[ "$(/usr/bin/plutil -extract Label raw -o - "$PLIST")" == "$LABEL" ]]
fi

NEXT_PLIST="$ROOT/build/$LABEL.plist"
/usr/bin/plutil -create xml1 "$NEXT_PLIST"
/usr/bin/plutil -insert Label -string "$LABEL" "$NEXT_PLIST"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$NEXT_PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$APP/Contents/MacOS/MacMonitorPreview" "$NEXT_PLIST"
/usr/bin/plutil -insert RunAtLoad -bool true "$NEXT_PLIST"
/usr/bin/plutil -insert KeepAlive -bool false "$NEXT_PLIST"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$NEXT_PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$STATE_DIR/launchd.out.log" "$NEXT_PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$STATE_DIR/launchd.err.log" "$NEXT_PLIST"
/usr/bin/plutil -lint "$NEXT_PLIST"

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$STATE_DIR"
chmod 700 "$STATE_DIR"
STAGING="$(mktemp -d "$HOME/Applications/.MacMonitorPreview.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$BUILT_APP" "$STAGING/MacMonitorPreview.app"
/usr/bin/codesign --verify --strict "$STAGING/MacMonitorPreview.app"

# 记录本测试版的进程及其采样子进程；不匹配旧版 App 或其他 macmon。
APP_PIDS=()
CHILD_PIDS=()
while read -r pid ppid executable; do
  if [[ "$executable" == "$BUILT_APP/Contents/MacOS/MacMonitorPreview" || "$executable" == "$APP/Contents/MacOS/MacMonitorPreview" ]]; then
    APP_PIDS+=("$pid")
  fi
done < <(/bin/ps -axo pid=,ppid=,comm=)
if [[ ${#APP_PIDS[@]} -gt 0 ]]; then
  while read -r pid ppid executable; do
    for app_pid in "${APP_PIDS[@]}"; do
      if [[ "$ppid" == "$app_pid" && "$executable" == */macmon ]]; then
        CHILD_PIDS+=("$pid")
      fi
    done
  done < <(/bin/ps -axo pid=,ppid=,comm=)
fi
if /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootout "$DOMAIN/$LABEL"
fi
if [[ ${#APP_PIDS[@]} -gt 0 ]]; then
  kill -TERM "${APP_PIDS[@]}" 2>/dev/null || true
fi
if [[ ${#CHILD_PIDS[@]} -gt 0 ]]; then
  kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null || true
fi

# 替换整个已验证的 bundle，保留上一版，不原地覆盖运行中的二进制。
if [[ -e "$APP" ]]; then
  mkdir -p "$STATE_DIR/previous-apps"
  mv "$APP" "$STATE_DIR/previous-apps/$(date +%Y%m%d-%H%M%S)-$$.app"
fi
mv "$STAGING/MacMonitorPreview.app" "$APP"
cp "$NEXT_PLIST" "$STAGING/$LABEL.plist"
chmod 644 "$STAGING/$LABEL.plist"
mv "$STAGING/$LABEL.plist" "$PLIST"
/bin/launchctl enable "$DOMAIN/$LABEL"
/bin/launchctl bootstrap "$DOMAIN" "$PLIST"
echo "已安装并启用登录自启动：$APP"
