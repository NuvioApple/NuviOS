#!/usr/bin/env bash
# Archives the Mac app and packages it into the DMG that ships to users.
#
#   ./make-dmg.sh            # signs with whatever the project resolves to
#   ./make-dmg.sh --notarize # additionally notarizes and staples
#
# Notarizing needs a Developer ID Application certificate and a stored
# notarytool credential profile (see README.md). Without one, the DMG is fine
# for local testing but Gatekeeper will block it on other people's Macs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
project="$here/../NuviOS.xcodeproj"
notarize=0
[ "${1:-}" = "--notarize" ] && notarize=1

build="$here/build"
rm -rf "$build"
mkdir -p "$build"

archive="$build/NuviOS.xcarchive"
export_dir="$build/export"

echo "==> Archiving"
xcodebuild archive \
    -project "$project" \
    -scheme NuviOS \
    -destination 'platform=macOS' \
    -configuration Release \
    -archivePath "$archive" \
    | tail -5

# `developer-id` is the method for a DMG distributed outside the App Store.
# It falls back to development signing when no Developer ID cert is present,
# which still produces a runnable app on this machine.
cat > "$build/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>MZT889Z6FM</string>
</dict>
</plist>
PLIST

echo "==> Exporting"
xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$build/ExportOptions.plist" \
    -exportPath "$export_dir" \
    | tail -5

app="$export_dir/NuviOS.app"
[ -d "$app" ] || { echo "export produced no NuviOS.app" >&2; exit 1; }

# Sparkle compares CFBundleVersion, so the DMG is named for the marketing
# version but the build number is what actually gates the update.
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
dmg="$here/NuvioOS-$version.dmg"

echo "==> Packaging $dmg"
stage="$build/stage"
mkdir -p "$stage"
cp -R "$app" "$stage/"
# The drag-to-install layout every Mac user already knows.
ln -s /Applications "$stage/Applications"

rm -f "$dmg"
hdiutil create \
    -volname "NuvioOS" \
    -srcfolder "$stage" \
    -ov -format UDZO \
    "$dmg" > /dev/null

if [ "$notarize" -eq 1 ]; then
    echo "==> Notarizing (this takes a few minutes)"
    xcrun notarytool submit "$dmg" --keychain-profile NuvioNotary --wait
    xcrun stapler staple "$dmg"
fi

echo "==> $dmg"
