//
//  Objective-C exposed to Swift.
//

#import <TargetConditionals.h>

// Google's YouTube iOS Player Helper, vendored from
// https://github.com/youtube/youtube-ios-player-helper (Apache 2.0) as the
// docs' "manual install" describes, because this project has no package
// manager wired up and the helper's own SPM manifest declares iOS only —
// which a target that also builds for tvOS can't resolve.
//
// It's iOS-only either way: it's a WKWebView wrapper, and tvOS has no WebKit.
#if TARGET_OS_IOS
#import "YTPlayerView.h"
#endif
