#!/usr/bin/env bash
# Signs a released DMG and regenerates the Sparkle feed next to it.
#
# Usage: ./make-appcast.sh path/to/NuvioOS-1.1.dmg v1.1
#
# The release notes Sparkle shows in its update dialog come from
# release-notes/<version>.md, which has to exist before a release can be cut.
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

# Sparkle shows whatever it finds in the appcast entry's description, and
# generate_appcast fills that from a notes file sitting next to the archive
# under the same basename. Without one the update dialog is a bare version
# number and an Install button, which tells nobody what they are installing.
base="$(basename "$dmg")"
version="${base#NuvioOS-}"
version="${version%.dmg}"
notes="$here/release-notes/$version.md"
if [ ! -f "$notes" ]; then
    echo "no release notes at $notes" >&2
    echo "Write them first — the update dialog reads from that file." >&2
    exit 1
fi
cp "$notes" "$staging/${base%.dmg}.md"

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
# Always regenerate rather than update in place: generate_appcast keeps
# fields like minimumSystemVersion from the existing entry, so a rebuild that
# lowers the deployment target would keep advertising the old, higher one and
# hide the update from exactly the machines it was lowered for.
rm -f "$here/appcast.xml"

# --embed-release-notes puts the notes inline in the feed. The alternative is
# a sparkle:releaseNotesLink to a separately hosted file, and only appcast.xml
# is published, so a linked file would 404 for every user.
"$generate_appcast" \
    --embed-release-notes \
    --download-url-prefix "https://github.com/NuvioApple/NuviOS/releases/download/$tag/" \
    -o "$here/appcast.xml" \
    "$staging"

echo "wrote $here/appcast.xml"
