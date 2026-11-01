#!/bin/bash
# Builds NuviOS for tvOS, installs it on your paired Apple TV and launches it, with a progress bar.
#
#   scripts/run-tv.sh [device name or UDID]     (default: the first paired Apple TV)
#
# The percentage compares build steps with the last run's count (saved in
# build/.tv-steps); the first run's percentage is rough.
set -uo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
LOG=build/tv.log
STEPS_FILE=build/.tv-steps
EXPECTED=$(cat "$STEPS_FILE" 2>/dev/null || echo 400)
DERIVED=build/tv-device
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

steps=0
draw 0 "Resolving packages…"
xcodebuild -project NuviOS.xcodeproj -scheme NuviOS -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build \
  2>&1 | tee "$LOG" | while IFS= read -r line; do
    if [[ $line =~ ^([A-Z][A-Za-z]+)\ (.*)$ ]]; then
      case ${BASH_REMATCH[1]} in Command|Build|Prepare|Resolve*|Resolved|Computing|User|Check*) continue ;; esac
      steps=$(( steps + 1 ))
      draw "$steps" "${BASH_REMATCH[1]}"
      echo "$steps" > build/.tv-steps.tmp
    fi
  done
status=${PIPESTATUS[0]}
steps=$(cat build/.tv-steps.tmp 2>/dev/null || echo 0); rm -f build/.tv-steps.tmp

if (( status != 0 )) || ! grep -q "BUILD SUCCEEDED" "$LOG"; then
  (( live )) && printf '\r\e[K'
  echo "${red}Build failed.${reset} Errors:"
  grep -E "error:" "$LOG" | sort -u | head -20
  echo "${dim}Full log: $LOG${reset}"
  exit 1
fi
echo "$steps" > "$STEPS_FILE"
(( live )) && printf '\r\e[K'
printf '%s\n' "$(bar 95)  Installing on the Apple TV…"

APP="$DERIVED/Build/Products/Debug-appletvos/NuviOS.app"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
  echo "${red}Install failed.${reset} Is the Apple TV awake and still paired? (Xcode → Window → Devices.)"
  tail -5 "$LOG"; exit 1
fi
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >> "$LOG" 2>&1 \
  || echo "${dim}Installed, but couldn't launch it (the Apple TV is probably asleep). Open it from the home screen.${reset}"
printf '%s\n' "$(bar 100)"
echo "${green}NuviOS is on your Apple TV.${reset}"
