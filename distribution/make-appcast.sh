#!/usr/bin/env bash
# Signs a released DMG and regenerates the Sparkle feed next to it.
#
# Usage: ./make-appcast.sh path/to/NuvioOS-1.1.dmg v1.1
#
# The tag is the GitHub release the DMG is uploaded to. It has to be pinned
# rather than left as "latest": the appcast keeps every past entry, and a
# `latest/download` URL would silently re-point old versions at the newest
# build the moment the next release goes out.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <path-to-dmg> <release-tag>" >&2
    exit 1
fi

dmg="$1"
tag="$2"
here="$(cd "$(dirname "$0")" && pwd)"

# generate_appcast ships with Sparkle. It wants a directory of releases, so it
# is pointed at a staging folder holding just the DMG being published; it
# reads the version out of the app inside and signs with the key in the
# keychain that generate_keys created.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp "$dmg" "$staging/"

generate_appcast="$(command -v generate_appcast || true)"
if [ -z "$generate_appcast" ]; then
    generate_appcast="$(find ~/Library/Developer/Xcode/DerivedData \
        -name generate_appcast -type f -perm -111 2>/dev/null | head -1)"
fi
if [ -z "$generate_appcast" ]; then
    echo "generate_appcast not found. Build the project once so SPM checks" >&2
    echo "out Sparkle, or download the Sparkle release tarball." >&2
    exit 1
fi

# The download URL prefix has to match where the DMG actually lands, or the
# feed will point clients at a 404.
"$generate_appcast" \
    --download-url-prefix "https://github.com/NuvioApple/NuviOS/releases/download/$tag/" \
    -o "$here/appcast.xml" \
    "$staging"

echo "wrote $here/appcast.xml"
