#!/bin/sh
# 썸네일 디렉터리의 *.jpg 목록을 JSON으로 저장 (thumb.html에서 실제 업로드 현황 표시용)
THUMB_DIR="${THUMB_DIR:-/var/www/static/live/thumb}"
OUT_FILE="${THUMB_DIR}/thumb-list.json"
cd "$THUMB_DIR" 2>/dev/null || exit 0
list=""
for f in *.jpg; do
  [ -f "$f" ] || continue
  id="${f%.jpg}"
  if [ -n "$list" ]; then list="$list,"; fi
  list="$list\"$id\""
done
echo "[${list}]" > "${OUT_FILE}.$$" && mv "${OUT_FILE}.$$" "$OUT_FILE"
