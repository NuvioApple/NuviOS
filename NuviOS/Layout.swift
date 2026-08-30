import SwiftUI

/// Size-derived metrics so one set of screens reads well on both a 1080p/4K TV
/// and a phone. Everything keys off the container width rather than the
/// platform, so the tvOS and iOS builds share a single layout.
///
/// The metrics *interpolate* rather than switch. A single breakpoint is fine
/// when there are only two sizes to serve, but the iOS build also runs in a
/// resizable window on iPad and on Mac: at 900pt wide a hard switch either
/// draws phone-sized artwork in a huge window or TV-sized artwork that
/// overflows it. Between `phoneWidth` and `tvWidth` every number slides.
struct LayoutMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat = 0

    /// The two widths the design was actually drawn at: an iPhone, and a
    /// 1080p/4K TV in points.
    private static let phoneWidth: CGFloat = 390
    private static let tvWidth: CGFloat = 1920

    /// 0 at phone width, 1 at TV width. Everything in between is a blend of
    /// the two designs rather than one of them stretched.
    var t: CGFloat {
        let span = Self.tvWidth - Self.phoneWidth
        return min(max((width - Self.phoneWidth) / span, 0), 1)
    }

    /// Blends the phone value and the TV value for the current width.
    func lerp(_ compact: CGFloat, _ regular: CGFloat) -> CGFloat {
        compact + (regular - compact) * t
    }

    /// Kept for the handful of decisions that genuinely are a switch rather
    /// than a scale — stacking a row into a column, dropping a line of copy.
    var isCompact: Bool { width < 700 }

    // MARK: Page

    var pagePadding: CGFloat { lerp(22, 80) }
    var sectionSpacing: CGFloat { lerp(28, 44) }
    var stackSpacing: CGFloat { lerp(14, 24) }

    var appTitleSize: CGFloat { lerp(40, 76) }
    var screenTitleSize: CGFloat { lerp(32, 58) }
    var bodyFont: Font { isCompact ? .subheadline : .title3 }
    var codeSize: CGFloat { lerp(22, 30) }

    /// Never wider than the space actually available, so it cannot overflow.
    var qrSize: CGFloat {
        let available = max(0, width - pagePadding * 2)
        return min(available, lerp(250, 320))
    }

    /// The code is grouped into blocks; four per line reads better on a phone.
    var codeGroupsPerLine: Int { isCompact ? 4 : 5 }

    // MARK: Chrome

    var topBarHeight: CGFloat { lerp(56, 92) }
    var wordmarkSize: CGFloat { lerp(20, 34) }

    // MARK: Hero

    /// The hero owns most of the first screenful, the way every streaming
    /// service opens, but always leaves a row peeking underneath so the shelf
    /// below reads as scrollable.
    ///
    /// The cap is the container's own height: a floor taller than the window
    /// is what made the hero overflow a part-screen Mac window.
    var heroHeight: CGFloat {
        let base = height > 0 ? height : width * 9 / 16
        let ideal = base * lerp(0.62, 0.72)
        let ceiling = height > 0 ? min(height * 0.86, lerp(620, 900)) : lerp(620, 900)
        return min(max(ideal, min(lerp(330, 520), ceiling)), ceiling)
    }

    var heroTitleSize: CGFloat { lerp(34, 74) }
    var heroLogoMaxWidth: CGFloat { min(width * lerp(0.7, 0.34), lerp(280, 620)) }
    var heroLogoMaxHeight: CGFloat { lerp(90, 200) }
    var heroContentWidth: CGFloat {
        min(width - pagePadding * 2, max(width * lerp(1, 0.46), lerp(320, 980)))
    }

    // MARK: Catalog rows

    var rowSpacing: CGFloat { lerp(28, 46) }
    var rowTitleSize: CGFloat { lerp(19, 31) }

    var posterWidth: CGFloat { lerp(118, 232).rounded() }
    var posterHeight: CGFloat { (posterWidth * 3 / 2).rounded() }
    var posterSpacing: CGFloat { lerp(12, 30) }
    var posterCornerRadius: CGFloat { lerp(10, 16) }

    /// tvOS grows the focused card, so a row needs slack around it — otherwise
    /// the grown card is clipped by the scroll view.
    var posterFocusPadding: CGFloat { lerp(6, 44) }

    /// How much a focused card grows. Big enough to be obvious across a room.
    var posterFocusScale: CGFloat { lerp(1.04, 1.10) }

    // MARK: Detail

    var detailPosterWidth: CGFloat { lerp(130, 300) }
    var detailBackdropHeight: CGFloat {
        let base = height > 0 ? height : width * 9 / 16
        return base * lerp(0.5, 0.78)
    }
}

/// A full-screen container over the app backdrop, centred the way the TV
/// layout did, that scrolls rather than clipping when space is tight.
struct Screen<Content: View>: View {
    var scrolls = true
    @ViewBuilder var content: (LayoutMetrics) -> Content

    var body: some View {
        GeometryReader { proxy in
            let metrics = LayoutMetrics(width: proxy.size.width, height: proxy.size.height)
            ZStack {
                NuvioBackground()

                if scrolls {
                    ScrollView {
                        body(metrics, height: proxy.size.height)
                    }
                } else {
                    body(metrics, height: proxy.size.height)
                }
            }
        }
    }

    private func body(_ metrics: LayoutMetrics, height: CGFloat) -> some View {
        content(metrics)
            .padding(.horizontal, metrics.pagePadding)
            .padding(.vertical, metrics.lerp(24, 56))
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
    }
}

/// Lays its children out in a row when there's room, a column when there isn't.
struct AdaptiveStack<Content: View>: View {
    let isVertical: Bool
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if isVertical {
            VStack(alignment: .leading, spacing: spacing) { content() }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}
