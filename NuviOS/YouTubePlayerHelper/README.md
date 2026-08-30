# YouTube iOS Player Helper (vendored)

`YTPlayerView.{h,m}` and `YTPlayerView-iframe-player.html` are unmodified
copies of Google's [youtube-ios-player-helper][repo], the library the
[official guide][guide] points to for embedding a YouTube player in an iOS
app. Apache 2.0; see `LICENSE`.

Vendored rather than added as a package because:

- the project has no package manager set up, and the guide documents dropping
  the sources in as a supported install; and
- the helper's `Package.swift` declares iOS only, so SPM refuses to resolve it
  for the tvOS half of this target.

`YTPlayerView.m` and the HTML are excluded from the tvOS SDK in the target's
build settings (`EXCLUDED_SOURCE_FILE_NAMES[sdk=appletv*]`), and the bridging
header only imports the header under `TARGET_OS_IOS`. tvOS has no WebKit, so
there is nothing to build there.

To update: re-download the three files from `Sources/` on the repo's default
branch. They are kept unmodified so that stays a straight copy.

[repo]: https://github.com/youtube/youtube-ios-player-helper
[guide]: https://developers.google.com/youtube/v3/guides/ios_youtube_helper
