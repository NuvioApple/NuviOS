<div align="center">

  <h1>NuviOS</h1>

  <p>
    The unofficial Apple port of Nuvio — iPhone, iPad, Apple TV and Mac, one SwiftUI app, one codebase.
    <br />
    Bring your own sources. NuviOS turns them into a library with artwork, subtitles, and your place saved on every screen.
  </p>

  [Website](https://nuvio.tv) · [Android](https://github.com/NuvioMedia/NuvioTV) · [Support Nuvio](https://nuvio.tv/support)

</div>

## Get NuviOS

**Mac** — download the latest [DMG](distribution/), drag NuviOS to Applications, and it keeps
itself up to date from then on: it checks once a day and installs on quit, or on demand from
**NuviOS → Check for Updates…**.

**iPhone, iPad and Apple TV** — build and install it yourself. There is no App Store build, and a
sideloaded install cannot update itself; whatever put it on the device has to replace it.

## What it does

- **Stremio-protocol addons** supply the catalogs, metadata and streams. Nothing is bundled — you
  point NuviOS at the addons you already use.
- **Two playback engines.** [AetherEngine](https://github.com/superuser404notfound/AetherEngine)
  runs first: FFmpeg demuxes and the platform decodes, so Dolby Vision stays a real display switch,
  Atmos is passed through rather than decoded to PCM, and tvOS Match Content drives the panel.
  Anything it cannot open falls back to libvlc, which opens practically everything else.
- **Debrid resolution** for Real-Debrid and TorBox, with links minted at the moment of playing
  rather than cached.
- **Profiles, watch progress and collections** sync across every device on the account.
- **Trailers** work out of the box from the addon's own metadata; a TMDB key is optional.
- **Your own backend.** NuviOS discovers a deployment from its `/.well-known/nuvio` document, so
  no keys are baked in and any Nuvio server will do — the hosted one is just the default.

## Build from source

Requires Xcode 26 or newer and an Apple developer account for signing.

```bash
git clone https://github.com/NuvioApple/NuviOS.git
```

Open `NuviOS.xcodeproj`, set your own team under Signing & Capabilities, pick a destination and run.
Swift Package Manager resolves AetherEngine, VLCKit and Sparkle on the first build.

Deployment targets are iOS/iPadOS 26, tvOS 26 and macOS 26.

## Releases

Mac releases are notarized DMGs published with a Sparkle appcast, cut from this repo — see
[distribution/README.md](distribution/README.md) for the full procedure.

## License

[GNU General Public License v3.0](https://github.com/NuvioMedia/NuvioTV/blob/main/LICENSE)
