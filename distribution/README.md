# Mac releases and over-the-air updates

The Mac build updates itself with [Sparkle](https://sparkle-project.org): it
checks a feed once a day, downloads the new DMG in the background and installs
it on quit. Users can also ask directly, from **Nuvio → Check for Updates…** or
the Updates section of the profile tab.

iOS, iPadOS and tvOS do not do this and cannot. Neither platform exposes an API
that installs a binary, so a sideloaded build is only ever replaced by the
sideloader that installed it.

## Setup (already done, recorded here for whoever inherits this)

**Signing key.** Sparkle verifies every update with an EdDSA signature; the
public half is `SUPublicEDKey` in `NuviotvOS/Info.plist`, and the private half
lives in the login keychain of the machine that cuts releases. It is not in
this repo and must not be.

If you are setting up a *second* release machine, export it from the first
rather than generating a new one — a new key invalidates every existing
install's ability to verify updates:

```bash
generate_keys -x sparkle-private-key.txt   # on the machine that has it
generate_keys -f sparkle-private-key.txt   # on the new machine, then delete the file
```

`generate_keys` lives in the Sparkle package Xcode checked out, under
`SourcePackages/artifacts/sparkle/Sparkle/bin` in DerivedData.

**Notarization credentials.** Apple must notarize the DMG or Gatekeeper blocks
it on every Mac but this one. Store the credential once:

```bash
xcrun notarytool store-credentials NuvioNotary --apple-id "<your-apple-id>" --team-id MZT889Z6FM
```

It asks for an app-specific password (appleid.apple.com → Sign-In and Security
→ App-Specific Passwords), not the account password. `NuvioNotary` is the
profile name `make-dmg.sh --notarize` expects.

## Cutting a release

1. **Bump the version.** In the Xcode project, raise `MARKETING_VERSION` (what
   users see) and `CURRENT_PROJECT_VERSION`. Sparkle compares
   `CFBundleVersion`, so the build number must increase every single release or
   existing installs will never see the update.

2. **Build and notarize the DMG.**

   ```bash
   ./make-dmg.sh --notarize
   ```

   Archives, exports with the Developer ID Application certificate, packages
   the drag-to-Applications DMG, then notarizes and staples it. Drop
   `--notarize` for a local test build — it will run on this machine but not on
   anyone else's.

3. **Sign the feed.**

   ```bash
   ./make-appcast.sh NuvioOS-<version>.dmg v<version>
   ```

   Signs the DMG with the private key and rewrites `appcast.xml`. The tag is
   the GitHub release the DMG will be uploaded to, and must match it exactly —
   it is baked into the download URL for this version forever.

4. **Publish.** Upload the DMG to the GitHub release, then commit the
   regenerated `appcast.xml` — `SUFeedURL` serves it from `main`, so the
   release is not live to existing installs until that commit lands.

Order matters in step 4: if the appcast is committed before the DMG is
uploaded, clients will find the update and fail to download it.

## Feed URL

`SUFeedURL` in `Info.plist` points at this directory's `appcast.xml` on `main`
in `NuvioApple/NuviOS`, and `make-appcast.sh` builds download URLs against that
repo's releases. Both must change together, and note that builds already in
users' hands keep asking the *old* URL forever — so if the feed ever moves, the
old address has to keep serving a valid appcast or those installs go dark.

This assumes `distribution/` sits at the repo root. If the Xcode project is
committed under a subdirectory instead, `SUFeedURL` must include it.
