#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$ROOT/build/public-repo}"
[[ ! -e "$DEST" ]] || { echo "导出目标已存在，停止以保护已有文件。" >&2; exit 1; }
mkdir -p "$DEST"
# 明确白名单：不导出整个 AI4MAC，也不导出试用证据、状态和构建缓存。
for directory in Sources Assets ThirdParty tools; do
  cp -R "$ROOT/$directory" "$DEST/$directory"
done
for file in Info.plist build.sh fetch-macmon.sh install.sh run.sh release.sh export-public.sh README.md INSTALL.md CHANGELOG.md LICENSE THIRD_PARTY_NOTICES.md; do
  cp "$ROOT/$file" "$DEST/$file"
done
cat > "$DEST/.gitignore" <<'EOF'
.DS_Store
build/
*.log
*.zip
*.dmg
EOF
echo "$DEST"
