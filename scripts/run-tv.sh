#!/bin/bash
# Builds NuviOS for tvOS, installs it on your paired Apple TV and launches it, with a progress bar.
#
#   scripts/run-tv.sh [device name or UDID]     (default: the first paired Apple TV)
#   JOBS=3 scripts/run-tv.sh                    fewer parallel compiles when the Mac is short on memory
#
# The percentage compares build steps with the last run's count (saved in
# build/.tv-steps); the first run's percentage is rough.
set -uo pipefail

cd "$(dirname "$0")/.."
# The build cache and log live on the internal disk, the way WatchGuide's do:
# /Volumes/Dev is a USB drive, and DerivedData on it makes every build crawl.
CACHE="$HOME/Library/Caches/NuviOSBuild"
mkdir -p "$CACHE"
LOG="$CACHE/tv.log"
STEPS_FILE="$CACHE/.tv-steps"
EXPECTED=$(cat "$STEPS_FILE" 2>/dev/null || echo 400)
DERIVED=${DERIVED:-$CACHE/tv-device}
BUNDLE_ID=tv.nuvio.unofficial.nuviotvos

bold=$'\e[1m'; dim=$'\e[2m'; green=$'\e[32m'; red=$'\e[31m'; reset=$'\e[0m'
started=$SECONDS

bar() {
  local filled=$(( $1 * 30 / 100 ))
  printf '[%s%s] %3d%%' "$(printf '%*s' "$filled" '' | tr ' ' '#')" "$(printf '%*s' $(( 30 - filled )) '' | tr ' ' '-')" "$1"
}

clock() { local s=$(( SECONDS - started )); printf '%dm%02ds' $(( s / 60 )) $(( s % 60 )); }

# One line, redrawn in place every second, with the time so far.
draw() { # draw <pct> <label>
  printf '\r\e[K%s  %-32s %s' "$(bar "$1")" "${2:0:32}" "$(clock)"
}

# The paired Apple TV: the argument if given, else the first physical Apple TV.
DEVICE=${1:-}
if [[ -z $DEVICE ]]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/Apple TV/ && /physical/ && /connected|available/ {
    for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')
fi
if [[ -z $DEVICE ]]; then
  echo "${red}No Apple TV found.${reset} Pair it with this Mac (Xcode → Window → Devices)."
  exit 1
fi

echo "${bold}Building NuviOS for Apple TV${reset} ${dim}($DEVICE)${reset}"

pct=0; steps=0; offset=0; label="Resolving packages"
draw 0 "$label"
: > "$LOG"
xcodebuild -project NuviOS.xcodeproj -scheme NuviOS -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates ${JOBS:+-jobs "$JOBS"} build \
  > "$LOG" 2>&1 &
bpid=$!

# Xcode goes quiet while NuviOS's own Swift compiles in one batch, so between
# real steps the bar creeps forward on an estimate and never looks stuck.
while kill -0 $bpid 2>/dev/null; do
  total=$(wc -l < "$LOG" | tr -d ' ')
  if (( total > offset )); then
    while IFS= read -r line; do
      if [[ $line =~ ^([A-Z][A-Za-z]+)\ (.*)$ ]]; then
        case ${BASH_REMATCH[1]} in Command|Build|Prepare|Resolve*|Resolved|Computing|User|Check*) continue ;; esac
        steps=$(( steps + 1 ))
        case ${BASH_REMATCH[1]} in
          SwiftCompile|SwiftDriver*|SwiftEmitModule|CompileSwift*) label="Compiling Swift" ;;
          Ld) label="Linking" ;;
          CodeSign) label="Signing" ;;
          *) label=${BASH_REMATCH[1]} ;;
        esac
      fi
    done < <(sed -n "$(( offset + 1 )),${total}p" "$LOG")
    offset=$total
  fi
  real=$(( steps * 100 / EXPECTED ))
  (( real > pct )) && pct=$real
  (( pct < 90 )) && (( SECONDS % 4 == 0 )) && pct=$(( pct + 1 ))
  (( pct > 94 )) && pct=94
  draw "$pct" "$label"
  sleep 1
done
wait $bpid; status=$?
printf '\n'

if (( status != 0 )) || ! grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo "${red}Build failed.${reset} Errors:"
  grep -E "error:" "$LOG" | sort -u | head -20
  echo "${dim}Full log: $LOG${reset}"
  exit 1
fi
echo "$steps" > "$STEPS_FILE"
draw 95 "Installing on the Apple TV"; printf '\n'

APP="$DERIVED/Build/Products/Debug-appletvos/NuviOS.app"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
  echo "${red}Install failed.${reset} Is the Apple TV awake and still paired? (Xcode → Window → Devices.)"
  tail -5 "$LOG"; exit 1
fi
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" >> "$LOG" 2>&1 \
  || echo "${dim}Installed, but couldn't launch it (the Apple TV is probably asleep). Open it from the home screen.${reset}"
draw 100 "Done"; printf '\n'
echo "${green}NuviOS is on your Apple TV.${reset}"
