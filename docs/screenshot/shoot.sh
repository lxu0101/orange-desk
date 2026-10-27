#!/bin/bash
# 用演示数据重新截 README 里的图（需要 Google Chrome）
set -e
cd "$(dirname "$0")/../.."
G="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
for sc in home chat study kb; do
  python3 - "$sc" "$TMP" <<'PY'
import sys
sc, tmp = sys.argv[1], sys.argv[2]
s = open("ui.html", encoding="utf-8").read()
h = open("docs/screenshot/harness.js", encoding="utf-8").read()
open(f"{tmp}/{sc}.html", "w", encoding="utf-8").write(s.replace("</body>", "<script>" + h + "</script>\n</body>"))
PY
  "$G" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,860 --force-device-scale-factor=2 \
    --virtual-time-budget=4000 --screenshot="docs/images/$sc.png" "file://$TMP/$sc.html#$sc" >/dev/null 2>&1
  echo "docs/images/$sc.png"
done
rm -rf "$TMP"
