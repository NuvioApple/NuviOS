#if os(iOS) || os(macOS) || os(tvOS)
import Observation
import SwiftUI

/// The size of the window the app is actually running in.
///
/// The iOS build is not only ever an iPhone: on iPad and on Mac it lives in a
/// window the user resizes, and a half-screen Mac window is neither a phone
/// nor a full screen. Every metric below is derived from this instead of
/// assumed, and `@Observable` means a resize invalidates the views that read
/// one without any of them having to observe it explicitly.
@Observable
final class Viewport {
    static let shared = Viewport()

    var size = CGSize(width: 390, height: 844)

    private init() {}
}

extension View {
    /// Feeds the size of the space a screen actually gets to `Phone`.
    func measuringViewport() -> some View {
        onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { new in
            guard new.width > 1, new.height > 1, new != Viewport.shared.size else { return }
            Viewport.shared.size = new
        }
    }

    /// The Mac shell keeps its destinations in a sidebar, so the window is
    /// wider than the column a screen is drawn in. Measured at the window, the
    /// billboard and the shelves are sized for room they do not have — the
    /// hero comes out taller than its column and the artwork is cropped to a
    /// black band. The Mac measures the content column instead; the phone and
    /// the iPad have their destinations in a bar over the content, where the
    /// window and the column are the same width, and keep measuring the root.
    @ViewBuilder
    func measuringContentViewport() -> some View {
        #if os(macOS)
        measuringViewport()
        #else
        self
        #endif
    }
}

/// Sizes for the phone layout. Kept apart from `LayoutMetrics` because the
/// iPhone shell is laid out for a thumb, not for a focus engine — but, like
/// `LayoutMetrics`, it scales continuously with the space it has rather than
/// switching at a breakpoint.
enum Phone {
    static var width: CGFloat { Viewport.shared.size.width }
    static var height: CGFloat { Viewport.shared.size.height }

    /// 1 at iPhone width, growing with the square root of it so a wide window
    /// gets bigger artwork without turning three posters into three
    /// billboards. Capped at 2, which lands on the TV layout's own sizes.
    static var scale: CGFloat { min(max((width / 390).squareRoot(), 1), 2) }

    static var pagePadding: CGFloat { (16 * scale).rounded() }
    static var posterWidth: CGFloat { (118 * scale).rounded() }
    static var posterHeight: CGFloat { (posterWidth * 3 / 2).rounded() }
    static var posterRadius: CGFloat { (10 * scale).rounded() }
    static var posterSpacing: CGFloat { (10 * scale).rounded() }
    static var shelfSpacing: CGFloat { (26 * scale).rounded() }
    /// Clears the floating glass tab bar so the last row stays reachable. The
    /// bar barely grows with the window, so neither does this. The Mac's
    /// destinations live in a sidebar instead, so nothing overlaps the bottom
    /// of the window there and only ordinary breathing room is needed.
    static var tabBarClearance: CGFloat {
        #if os(macOS)
        (24 * min(scale, 1.3)).rounded()
        #else
        (64 * min(scale, 1.3)).rounded()
        #endif
    }

    // MARK: Billboard

    /// The billboard's shape: portrait on a phone, the proportion Netflix and
    /// Disney+ use on a wide window. Interpolated across the middle so
    /// dragging a window edge doesn't snap the header into a new shape.
    static var billboardAspect: CGFloat {
        let t = min(max((width - 600) / 400, 0), 1)
        return 0.72 + (1.9 - 0.72) * t
    }

    /// The billboard is never taller than the window it sits in. Deriving the
    /// height from the width alone is what made a wide, short Mac window open
    /// on a hero several screenfuls tall.
    static var billboardHeight: CGFloat {
        let byShape = width / billboardAspect
        let ceiling = max(height * 0.78, 280)
        return min(byShape, ceiling).rounded()
    }

    /// Type and controls keep a readable measure however wide the window gets,
    /// rather than a title stretched across a metre of desk.
    static var billboardContentWidth: CGFloat { min(width - pagePadding * 2, 680) }

    static var billboardLogoWidth: CGFloat { min(280 * scale, billboardContentWidth) }
    static var billboardLogoHeight: CGFloat { (110 * scale).rounded() }
    static var billboardTitleSize: CGFloat { (32 * scale).rounded() }

    // MARK: Detail page

    /// The detail page's artwork header, sized the same way the billboard is:
    /// a portrait crop on a phone, a cinematic one on a wide window, and never
    /// taller than the window itself.
    static var detailArtworkAspect: CGFloat {
        let t = min(max((width - 600) / 400, 0), 1)
        return 0.78 + (1.9 - 0.78) * t
    }

    static var detailArtworkHeight: CGFloat {
        min(width / detailArtworkAspect, max(height * 0.72, 260)).rounded()
    }

    /// Body copy stops at a readable measure instead of running the full width
    /// of a maximised window.
    static var readableWidth: CGFloat { min(width - pagePadding * 2, 720) }

    /// The gap under the controls. It rides on the billboard's own height so
    /// the copy stays clear of the bottom edge at every size.
    static var billboardBottomInset: CGFloat { min(max(billboardHeight * 0.07, 20), 48) }
}

// MARK: - Interaction

/// Shrinks a card while it's held, the way every streaming app answers a tap
/// on artwork. Replaces `.buttonStyle(.plain)`, which gives no feedback at all.
///
/// On a television there is no press to answer, there is focus — and focus
/// with no visible answer is an unusable screen, because the viewer cannot
/// see where the remote is pointing. So the same style lifts the control when
/// it takes focus, and every `.pressable` call site in the app gains the
/// television's affordance without being touched.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    /// How much the control grows on focus. Cards pass a larger value; small
    /// controls keep the default, which is about as much as a capsule can
    /// grow without colliding with its neighbours.
    var focusScale: CGFloat = 1.08

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        FocusReader { isFocused in
            configuration.label
                .scaleEffect(configuration.isPressed ? scale : (isFocused ? focusScale : 1))
                .brightness(isFocused ? 0.08 : 0)
                .zIndex(isFocused ? 1 : 0)
                .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 24, y: 12)
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
        #else
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
        #endif
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }

    /// For artwork: a smaller press, a bigger focus lift.
    static var pressableCard: PressableStyle {
        PressableStyle(scale: 0.97, focusScale: 1.10)
    }
}

// MARK: - Posters

/// One piece of artwork in a row.
///
/// The title sits *under* the poster only when the artwork has no embedded
/// one to fall back on — Netflix and Disney+ both let the poster speak, and a
/// caption under every card turns a row into a table.
struct PosterCard: View {
    let item: MetaItem
    let addonBaseURL: String
    /// 1-based position, drawn as a large numeral beside the poster. Only the
    /// ranked rows pass this.
    var rank: Int?
    var width: CGFloat = Phone.posterWidth
    let action: () -> Void

    private var height: CGFloat { (width * 3 / 2).rounded() }
    /// The hovered card keeps the poster's height and widens to 16:9, so a
    /// shelf stays one consistent height whatever the pointer is over.
    private var landscapeWidth: CGFloat { (height * 16 / 9).rounded() }

    #if os(macOS)
    /// The Mac is the only platform with a pointer, so it is the only one that
    /// can have a hover state at all. The phone has no hover and the TV moves
    /// by focus, which already has its own treatment.
    @State private var isHovering = false
    #endif

    var body: some View {
        Button(action: action) {
            // The card reads its own focus so the television gets the frame
            // and the caption it needs, and the phone — which never focuses —
            // keeps exactly the card it had.
            FocusReader { isFocused in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: rank == nil ? 0 : -width * 0.34) {
                        if let rank {
                            RankNumeral(rank: rank, height: height)
                        }
                        poster
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: Phone.posterRadius,
                                    style: .continuous
                                )
                                .strokeBorder(.white.opacity(isFocused ? 1 : 0), lineWidth: 4)
                            }
                    }

                    caption(isFocused: isFocused)
                }
            }
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel(rank.map { "\(item.name), number \($0)" } ?? item.name)
    }

    /// The title under the artwork. A phone lets the poster speak for itself —
    /// a caption under every card turns a row into a table — but across a room
    /// a poster is too small to read, so the focused card, and only the
    /// focused card, says what it is. The space is reserved either way so the
    /// shelf doesn't jump as focus moves along it.
    @ViewBuilder
    private func caption(isFocused: Bool) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let year = item.releaseInfo?.trimmed, !year.isEmpty {
                Text(year)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(height: 46, alignment: .top)
        .opacity(isFocused ? 1 : 0)
        #else
        EmptyView()
        #endif
    }

    /// Hovering swaps the portrait poster for the title's landscape backdrop,
    /// the way the TV app turns a tile over under the pointer.
    ///
    /// The card grows sideways rather than in both directions: it holds the
    /// poster's height and widens to 16:9, so the shelf stays exactly as tall
    /// as it was and the neighbouring cards slide aside to make the room.
    /// Titles whose addon sends no backdrop keep the poster and simply crop to
    /// the wider shape rather than popping to a grey well.
    private var artworkURL: URL? {
        AddonClient.resolve(item.poster, relativeTo: addonBaseURL)
    }

    #if os(macOS)
    /// The landscape art, when the addon sent any.
    private var backdropURL: URL? {
        guard let background = item.background?.trimmed, !background.isEmpty else { return nil }
        return AddonClient.resolve(background, relativeTo: addonBaseURL)
    }
    #endif

    private var artworkWidth: CGFloat {
        #if os(macOS)
        isHovering ? landscapeWidth : width
        #else
        width
        #endif
    }

    private var poster: some View {
        artwork
        .frame(width: artworkWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Phone.posterRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Phone.posterRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if let rating = item.imdbRating?.trimmed, !rating.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                    Text(rating)
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassPill()
                .padding(5)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        #if os(macOS)
        // Slower than a click's worth of feedback and eased at both ends: the
        // card is drifting open under a pointer that may only be passing over
        // it, not answering a press.
        .animation(.easeInOut(duration: 0.42), value: isHovering)
        .onHover { hovering in isHovering = hovering }
        #endif
    }

    /// Poster and backdrop are drawn as one stack and cross-faded, rather than
    /// one image view whose URL changes.
    ///
    /// Swapping the URL is what made the hover snap: the poster vanishes the
    /// instant the pointer lands, and the backdrop pops in whenever the
    /// network happens to deliver it — so the card blinks through its own
    /// placeholder on the way. Holding both and moving opacity means the
    /// backdrop is already decoded by the time it is asked to appear, and the
    /// two dissolve into each other instead.
    @ViewBuilder
    private var artwork: some View {
        #if os(macOS)
        // Both images are pinned to the card's own size and clipped there.
        // Without that the 16:9 backdrop — which fills, and so grows to
        // whatever it is offered — sizes the stack to its own filled
        // dimensions, and the poster stacked with it fills that larger
        // proposal too, rendering blown up inside the card.
        ZStack {
            RemoteImage(url: artworkURL) { AnyView(fallback) }
                .frame(width: artworkWidth, height: height)
                .clipped()
                .opacity(isShowingBackdrop ? 0 : 1)

            if let backdropURL {
                RemoteImage(url: backdropURL) { AnyView(EmptyView()) }
                    .frame(width: artworkWidth, height: height)
                    .clipped()
                    .opacity(isShowingBackdrop ? 1 : 0)
            }
        }
        .frame(width: artworkWidth, height: height)
        #else
        RemoteImage(url: artworkURL) { AnyView(fallback) }
        #endif
    }

    #if os(macOS)
    /// A title with no backdrop still widens, but keeps its poster rather than
    /// fading to nothing.
    private var isShowingBackdrop: Bool { isHovering && backdropURL != nil }
    #endif

    /// Addons without poster art still have to be tappable and identifiable,
    /// so the fallback carries the name rather than a broken-image well.
    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [.white.opacity(0.10), .white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: item.type.lowercased() == "series" ? "tv" : "film")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.35))
                Text(item.name)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(8)
        }
    }
}

/// The oversized outlined numeral in a ranked row.
private struct RankNumeral: View {
    let rank: Int
    let height: CGFloat

    var body: some View {
        Text("\(rank)")
            .font(.system(size: height * 0.62, weight: .heavy, design: .rounded))
            // Sits at background level, the way a ranked row's numerals do
            // everywhere else: present, but never competing with the artwork.
            .foregroundStyle(.white.opacity(0.18))
            .fixedSize()
            .padding(.bottom, -height * 0.06)
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// A titled horizontal row of artwork.
struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    /// The addon that supplied the row, shown small and quiet — it matters
    /// when two addons publish rows with the same name.
    var subtitle: String?
    var isRanked = false
    let items: [Item]
    @ViewBuilder var card: (Item, Int) -> Card
    var onSeeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title, subtitle: subtitle, onSeeAll: onSeeAll)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: isRanked ? 2 : Phone.posterSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        card(item, offset)
                    }
                }
                .padding(.horizontal, Phone.pagePadding)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }
}

struct ShelfHeader: View {
    let title: String
    var subtitle: String?
    var onSeeAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let onSeeAll {
                Button(action: onSeeAll) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("See all \(title)")
            }
        }
        .padding(.horizontal, Phone.pagePadding)
    }
}

// MARK: - Placeholders

struct PosterPlaceholder: View {
    var body: some View {
        SkeletonBlock(cornerRadius: Phone.posterRadius)
            .frame(width: Phone.posterWidth, height: Phone.posterHeight)
    }
}

struct ShelfPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(cornerRadius: 6)
                .frame(width: 150, height: 20)
                .padding(.horizontal, Phone.pagePadding)

            HStack(spacing: Phone.posterSpacing) {
                ForEach(0..<5, id: \.self) { _ in PosterPlaceholder() }
            }
            .padding(.horizontal, Phone.pagePadding)
        }
    }
}

/// Shown when a screen has nothing to display.
struct EmptyState: View {
    let message: String
    var systemImage = "square.stack.3d.up.slash"
    var onRetry: (() -> Void)?

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.accent)

            Text("Nothing to show")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            if let onRetry {
                Button("Try again", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.glassProminent)
                    .tint(palette.accent)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .glassCard()
    }
}

// MARK: - Top bar

/// The floating header Netflix, Disney+ and the Apple TV app all share:
/// transparent over the billboard, then a glass bar once you scroll into the
/// rows. The profile's face sits in the trailing corner, where tapping it
/// switches who is watching.
struct FloatingTopBar<Trailing: View>: View {
    /// 0 at the top of the page, 1 once the billboard has scrolled away.
    let progress: Double
    @ViewBuilder var leading: () -> AnyView
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, Phone.pagePadding)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(progress)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.white.opacity(0.08 * progress))
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .top)
        }
    }
}

/// Tracks how far a scroll view has travelled, normalised over `distance`.
/// Used to fade the top bar in as the billboard leaves.
struct ScrollProgress: ViewModifier {
    let distance: CGFloat
    @Binding var progress: Double

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Double.self) { geometry in
            let offset = geometry.contentOffset.y + geometry.contentInsets.top
            return min(1, max(0, Double(offset / distance)))
        } action: { _, new in
            progress = new
        }
    }
}

extension View {
    func trackingScrollProgress(over distance: CGFloat, into progress: Binding<Double>) -> some View {
        modifier(ScrollProgress(distance: distance, progress: progress))
    }
}
#endif
