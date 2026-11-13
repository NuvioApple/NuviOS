#!/bin/bash
# Live progress for a GitHub release upload, redrawn every second.
#   scripts/watch-upload.sh <file being uploaded> <tag>
FILE=${1:?file}; TAG=${2:?tag}
TOTAL=$(stat -f %z "$FILE")
started=$SECONDS
bar() { local f=$(( $1 * 30 / 100 )); printf '[%s%s] %3d%%' "$(printf '%*s' $f '' | tr ' ' '#')" "$(printf '%*s' $((30-f)) '' | tr ' ' '-')" "$1"; }
echo "Uploading $(basename "$FILE") to $TAG"
while p=$(pgrep -x gh | head -1); [ -n "$p" ]; do
  b=$(nettop -P -L 1 -p "$p" -J bytes_out 2>/dev/null | tail -1 | cut -d, -f2); b=${b:-0}
  pct=$(( b * 100 / TOTAL )); (( pct > 100 )) && pct=100
  s=$(( SECONDS - started ))
  printf '\r\e[K%s  %d / %d MB  %dm%02ds' "$(bar $pct)" $((b/1048576)) $((TOTAL/1048576)) $((s/60)) $((s%60))
  sleep 1
done
printf '\r\e[K%s  Upload done\n' "$(bar 100)"
gh release view "$TAG" --json isDraft,assets,url \
  -q '"Draft: \(.isDraft)\n\([.assets[] | "  \(.name)  \(.size) bytes  \(.state)"] | join("\n"))\n\(.url)"'
