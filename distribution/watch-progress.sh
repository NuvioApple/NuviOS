#!/usr/bin/env bash
# Shows make-dmg.sh's progress as one updating bar, from another terminal.
# Reads the build log and the line-count baselines make-dmg.sh records.
here="$(cd "$(dirname "$0")" && pwd)"
log="${BUILD_DIR:-$here/build}/xcodebuild.log"
archive_total="$(cat "$here/.progress/archive" 2>/dev/null || echo 0)"
width=40

while true; do
    n=$(wc -l < "$log" 2>/dev/null || echo 0); n=${n// /}
    if [ -d "$here/build/export" ] || ! pgrep -f make-dmg.sh >/dev/null; then
        phase="Exporting / packaging DMG"; pct=99
        pgrep -f make-dmg.sh >/dev/null || { phase="Done"; pct=100; }
    elif [ "$archive_total" -gt 0 ]; then
        phase="Archiving"; pct=$((n * 100 / archive_total)); [ "$pct" -gt 99 ] && pct=99
    else
        phase="Archiving"; pct=0
    fi
    filled=$((pct * width / 100))
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((width - filled)) '' | tr ' ' '-')"
    printf '\r  %-28s [%s] %3d%%' "$phase" "$bar" "$pct"
    [ "$pct" -eq 100 ] && { echo; ls -lh "$here"/NuvioOS-*.dmg 2>/dev/null | tail -1; break; }
    sleep 1
done
