#!/bin/bash
# 用演示数据重新截 README 里的图（需要 Google Chrome）：中文版在 docs/images/，英文版在 docs/images/en/
set -e
cd "$(dirname "$0")/../.."
G="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
mkdir -p docs/images/en
for sc in home chat study kb; do
  python3 - "$sc" "$TMP" <<'PY'
import sys
sc, tmp = sys.argv[1], sys.argv[2]
s = open("ui.html", encoding="utf-8").read()
h = open("docs/screenshot/harness.js", encoding="utf-8").read()
open(f"{tmp}/{sc}.html", "w", encoding="utf-8").write(s.replace("</body>", "<script>" + h + "</script>\n</body>"))
PY
  for lang in zh en; do
    out="docs/images/$sc.png"; hash="$sc"
    [ "$lang" = en ] && { out="docs/images/en/$sc.png"; hash="$sc-en"; }
    "$G" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,860 --force-device-scale-factor=2 \
      --virtual-time-budget=4000 --screenshot="$out" "file://$TMP/$sc.html#$hash" >/dev/null 2>&1
    echo "$out"
  done
done
rm -rf "$TMP"
