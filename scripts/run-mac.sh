#!/bin/bash
# Builds NuviOS for this Mac and opens it, with a progress bar.
#
#   scripts/run-mac.sh
#
# The percentage compares build steps with the last run's count (saved in
# build/.mac-steps); the first run's percentage is rough.
set -uo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
LOG=build/mac.log
STEPS_FILE=build/.mac-steps
EXPECTED=$(cat "$STEPS_FILE" 2>/dev/null || echo 400)
DERIVED=${DERIVED:-build/mac-run}
BUNDLE_ID=tv.nuvio.unofficial.nuviotvos

bold=$'\e[1m'; dim=$'\e[2m'; green=$'\e[32m'; red=$'\e[31m'; reset=$'\e[0m'
[[ -t 1 ]] && live=1 || live=0
last_pct=-1

bar() {
  local filled=$(( $1 * 30 / 100 ))
  printf '[%s%s] %3d%%' "$(printf '%*s' "$filled" '' | tr ' ' '#')" "$(printf '%*s' $(( 30 - filled )) '' | tr ' ' '-')" "$1"
}

draw() { # draw <done> <label>
  local pct=$(( $1 * 100 / EXPECTED )) cols
  (( pct > 99 )) && pct=99
  if (( live )); then
    cols=$(tput cols 2>/dev/null || echo 100); (( cols < 60 )) && cols=100
    printf '\r\e[K%s  %s' "$(bar "$pct")" "${2:0:$(( cols - 45 ))}"
  elif (( pct / 10 != last_pct / 10 )); then
    printf '%s  %s\n' "$(bar "$pct")" "$2"
  fi
  last_pct=$pct
}

echo "${bold}Building NuviOS for this Mac${reset}"

steps=0
draw 0 "Resolving packages…"

# xcodebuild fetches packages silently, so watch them land on disk instead.
PKGS="$DERIVED/SourcePackages"
EXPECTED_PKGS=$(find NuviOS.xcodeproj -name Package.resolved -exec grep -o '"identity" : "[^"]*"' {} \; 2>/dev/null | cut -d'"' -f4)
watch_packages() {
  local seen="" name size
  while :; do
    for name in $EXPECTED_PKGS; do
      [[ " $seen " == *" $name "* ]] && continue
      if ls -d "$PKGS"/checkouts/* 2>/dev/null | grep -qi "/$name$"; then
        seen="$seen $name"
        size=$(du -sh "$(ls -d "$PKGS"/checkouts/* | grep -i "/$name$")" 2>/dev/null | cut -f1)
        (( live )) && printf '\r\e[K'
        printf '  %s✓%s %s %s(%s)%s\n' "$green" "$reset" "$name" "$dim" "$size" "$reset"
      fi
    done
    size=$(du -sh "$PKGS" 2>/dev/null | cut -f1)
    (( live )) && printf '\r\e[K%s  Resolving packages… %s downloaded' "$(bar 0)" "${size:-0B}"
    [[ -f "$LOG" ]] && grep -qE "^(Resolved source packages|ComputePackagePrebuildTargetDependencyGraph|CreateBuildDescription|error:)" "$LOG" && break
    sleep 1
  done
  (( live )) && printf '\r\e[K'
  echo "  ${green}All packages resolved.${reset}"
}
rm -f "$LOG"
watch_packages &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null' EXIT
xcodebuild -project NuviOS.xcodeproj -scheme NuviOS -configuration Debug \
  -destination "platform=macOS" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build \
  2>&1 | tee "$LOG" | while IFS= read -r line; do
    # Package resolution: one line per package, kept on screen above the bar.
    if [[ $line =~ ^(Fetching|Cloning|Updating|Checking\ out|Computing\ version|Downloading|Fetched|Downloaded)\ (.*)$ ]]; then
      (( live )) && printf '\r\e[K'
      printf '  %s📦 %s %s%s\n' "$dim" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]##*/}" "$reset"
      draw "$steps" "Resolving packages…"
      continue
    fi
    if [[ $line =~ ^([A-Z][A-Za-z]+)\ (.*)$ ]]; then
      case ${BASH_REMATCH[1]} in Command|Build|Prepare|Resolve*|Resolved|Computing|User|Check*) continue ;; esac
      steps=$(( steps + 1 ))
      draw "$steps" "${BASH_REMATCH[1]}"
      echo "$steps" > build/.mac-steps.tmp
    fi
  done
status=${PIPESTATUS[0]}
steps=$(cat build/.mac-steps.tmp 2>/dev/null || echo 0); rm -f build/.mac-steps.tmp

if (( status != 0 )) || ! grep -q "BUILD SUCCEEDED" "$LOG"; then
  (( live )) && printf '\r\e[K'
  echo "${red}Build failed.${reset} Errors:"
  grep -E "error:" "$LOG" | sort -u | head -20
  echo "${dim}Full log: $LOG${reset}"
  exit 1
fi
(( steps > EXPECTED / 2 )) && echo "$steps" > "$STEPS_FILE"
(( live )) && printf '\r\e[K'
pkill -x NuviOS 2>/dev/null; sleep 1
open "$DERIVED/Build/Products/Debug/NuviOS.app"
printf '%s\n' "$(bar 100)"
echo "${green}NuviOS is open on this Mac.${reset}"
