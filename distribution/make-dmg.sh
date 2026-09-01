#!/usr/bin/env bash
# Archives the Mac app and packages it into the DMG that ships to users.
#
#   ./make-dmg.sh            # signs with whatever the project resolves to
#   ./make-dmg.sh --notarize # additionally notarizes and staples
#
# Notarizing needs a Developer ID Application certificate and a stored
# notarytool credential profile (see README.md). --notarize checks for both up
# front and refuses to start without them. Plain ./make-dmg.sh still builds an
# unnotarized DMG, which is fine for local testing but which Gatekeeper blocks
# on other people's Macs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
project="$here/../NuviOS.xcodeproj"
notarize=0
[ "${1:-}" = "--notarize" ] && notarize=1

# Notarizing is a long, slow round trip; check the prerequisites before
# spending ten minutes on an archive that cannot possibly be accepted.
if [ "$notarize" -eq 1 ]; then
    if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
        echo "no Developer ID Application certificate in the keychain." >&2
        echo "Apple only notarizes builds signed with one; an Apple Development" >&2
        echo "certificate is not enough. See README.md." >&2
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile NuvioNotary >/dev/null 2>&1; then
        echo "no usable NuvioNotary credential profile." >&2
        echo "Create it with xcrun notarytool store-credentials; see README.md." >&2
        exit 1
    fi
fi

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
# signingCertificate pins it to the Developer ID cert so the export fails
# outright rather than quietly falling back to development signing, which
# produces a runnable app that the notary service will always reject.
cat > "$build/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
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

    # Prove it, rather than trusting that the steps above did what they say.
    # This is what Gatekeeper will do on a machine that has never seen the app:
    # a stapled ticket means it verifies even with no network.
    echo "==> Verifying"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    echo "==> Notarized, stapled and verified"
fi

echo "==> $dmg"
