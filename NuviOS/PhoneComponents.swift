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

    /// The Mac measures the column a screen is actually drawn in rather than
    /// the window around it, so the billboard and the shelves are never sized
    /// for room they do not have — measured at the window, the hero comes out
    /// taller than its column and the artwork is cropped to a black band. The
    /// phone and the iPad have their destinations in a bar over the content,
    /// where the window and the column are the same width, and keep measuring
    /// the root.
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
    /// destinations live in the tab bar across the top instead, so nothing
    /// overlaps the bottom of the window there and only ordinary breathing
    /// room is needed.
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

// MARK: - Shelf expansion

#if os(macOS)
/// What a shelf knows about the one card in it that is currently open.
///
/// A card opens *over* the shelf: its own slot never changes size, so nothing
/// it does can move the shelf under a pointer that is standing still. The room
/// it needs is made by the cards after it standing aside — an offset, which is
/// drawn and hit-tested where you see it, and which leaves the layout, the
/// content size and the scroll position exactly as they were.
///
/// The cards after the open one carry most of that room. A card near the end of
/// a row has little room after it and would be cut off at the edge, so there the
/// cards before it give up room too and the whole run slides left — the open
/// card is always shown whole, whichever end of the row it sits at.
@MainActor
@Observable
final class ShelfExpansion {
    /// Which slot along the shelf is open.
    var expandedSlot: Int?
    /// The row is being scrolled right now.
    ///
    /// Cards pass under a still pointer while a row scrolls, and every one of
    /// them is hovered on the way past. Opening any of those is answering the
    /// scroll, not the pointer — so while this is true the cards hold whatever
    /// they were, and settle up when the scrolling stops.
    var isScrolling = false
    /// How much wider the open card is than the slot it sits in — exactly the
    /// distance the cards after it have to stand aside.
    var extraWidth: CGFloat = 0

    func open(slot: Int, extraWidth: CGFloat) {
        expandedSlot = slot
        self.extraWidth = extraWidth
    }

    func close(slot: Int) {
        // Only the card that opened may close: a pointer moving from one card
        // straight to the next reports the new card's opening before the old
        // card's closing, and a stale close would cancel the fresh open.
        guard expandedSlot == slot else { return }
        expandedSlot = nil
    }
}

/// How a wrapping row of cards is laid out, which is what says whether the card
/// that is open has the room to open into.
struct RowMetrics {
    /// How many cards fit across before the row wraps.
    let columnsPerRow: Int
    /// The width of one card's slot.
    let slotWidth: CGFloat
    /// Slot to slot: the slot's width plus the gap after it.
    let pitch: CGFloat

    /// How far the open card in `slot` has to pull its row left so that its
    /// full width lands inside the row rather than off the end of it — limited
    /// by the room actually in front of it, since a row cannot slide further
    /// left than its own first card.
    func leftShift(forSlotOpenAt slot: Int, extraWidth: CGFloat) -> CGFloat {
        guard columnsPerRow > 0 else { return 0 }

        let column = slot % columnsPerRow
        let gap = pitch - slotWidth
        // From the open card's leading edge to the end of its row.
        let roomAfter = CGFloat(columnsPerRow - column) * pitch - gap
        let overflow = max(slotWidth + extraWidth - roomAfter, 0)
        let roomBefore = CGFloat(column) * pitch

        return min(overflow, roomBefore)
    }
}

/// The line or two a card shows about a title while it is open.
///
/// A catalog row carries only what the addon chose to put in it, and plenty of
/// them leave the description out of a row and keep it for the title's own meta
/// response — so a card that has no description asks for one the moment the
/// pointer settles on it, in the time it is already waiting before it opens.
///
/// Answers are kept for the life of the launch. A row scrolled past and come
/// back to asks nothing, and a title in three rows at once is fetched once.
@MainActor
@Observable
final class SynopsisCache {
    static let shared = SynopsisCache()

    private var byKey: [String: String] = [:]
    /// Keys being fetched right now, so a pointer wavering over one card can't
    /// put the same request out twice.
    private var inFlight: Set<String> = []

    private init() {}

    /// What this card can show: the row's own description if it came with one,
    /// otherwise whatever the fetch has since brought back.
    func synopsis(for item: MetaItem, addonBaseURL: String) -> String? {
        if let own = item.description?.trimmed, !own.isEmpty { return Self.shortened(own) }

        return byKey[Self.key(item, addonBaseURL)]
    }

    func fetchIfNeeded(for item: MetaItem, addonBaseURL: String) {
        guard (item.description?.trimmed ?? "").isEmpty, !addonBaseURL.isEmpty else { return }

        let key = Self.key(item, addonBaseURL)
        guard byKey[key] == nil, !inFlight.contains(key) else { return }

        inFlight.insert(key)
        Task { @MainActor in
            let detail = try? await AddonClient().meta(
                baseURL: addonBaseURL,
                type: item.type,
                id: item.id
            )
            inFlight.remove(key)
            guard let text = detail?.description?.trimmed, !text.isEmpty else { return }

            byKey[key] = Self.shortened(text)
        }
    }

    /// A card is not a detail page. Two lines is what there is room for beside
    /// the artwork, so a synopsis is cut to the end of the last full sentence
    /// that fits and given an ellipsis to say that it goes on.
    static func shortened(_ text: String, limit: Int = 180) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmed
        guard clean.count > limit else { return clean }

        let head = String(clean.prefix(limit))
        // Prefer a sentence's own ending, and settle for a word's.
        if let sentence = head.range(of: ". ", options: .backwards), head.distance(
            from: head.startIndex,
            to: sentence.lowerBound
        ) > limit / 2 {
            return String(head[head.startIndex..<sentence.lowerBound]) + "."
        }
        if let space = head.range(of: " ", options: .backwards) {
            return String(head[head.startIndex..<space.lowerBound]) + "…"
        }

        return head + "…"
    }

    private static func key(_ item: MetaItem, _ addonBaseURL: String) -> String {
        "\(addonBaseURL)|\(item.type)|\(item.id)"
    }
}

/// A card's position along the shelf holding it, which is how it tells that
/// shelf which cards are the ones after it. Absent outside a shelf.
private struct ShelfSlotKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var shelfSlot: Int? {
        get { self[ShelfSlotKey.self] }
        set { self[ShelfSlotKey.self] = newValue }
    }
}

extension View {
    /// Places a card in a row of cards that make room for whichever of them is
    /// open: it learns its own position, and moves aside when a card in its own
    /// row opens.
    ///
    /// `metrics` is what tells a grid from a shelf. A shelf is one long row that
    /// scrolls and is not clipped at its ends, so every later card simply stands
    /// aside. A grid wraps and *is* clipped at the column's edge, so it also
    /// needs to know its own shape: only the open card's own row moves — the
    /// rows below it are not in its way and must not lurch sideways — and a
    /// card opening near the end of a row pulls that row left rather than
    /// opening off the edge of the screen.
    func standingAside(
        for expansion: ShelfExpansion,
        slot: Int,
        metrics: RowMetrics? = nil
    ) -> some View {
        let distance: CGFloat = {
            guard let open = expansion.expandedSlot else { return 0 }

            var shift: CGFloat = 0
            if let metrics, metrics.columnsPerRow > 0 {
                guard slot / metrics.columnsPerRow == open / metrics.columnsPerRow else { return 0 }
                // Every card in the row gives up the same ground, so the cards
                // keep their spacing and only the row's leading end runs off
                // the edge.
                shift -= metrics.leftShift(
                    forSlotOpenAt: open,
                    extraWidth: expansion.extraWidth
                )
            }
            // On top of that, the cards after the open one carry the width it
            // spills over them.
            if slot > open { shift += expansion.extraWidth }

            return shift
        }()

        return self
            .environment(\.shelfSlot, slot)
            // An offset, not a resize: the row's layout, content size and
            // scroll position are untouched, so the only thing that ever moves
            // under the pointer is a card getting out of its way.
            .offset(x: distance)
            .animation(.easeInOut(duration: 0.42), value: distance)
    }
}
#endif

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
    ///
    /// The pointer having rested on the card long enough that turning it over
    /// is an answer to intent rather than to a pointer crossing the shelf.
    /// Hovering alone starts the backdrop loading; only this opens the card.
    @State private var isExpanded = false
    /// The card is loading its backdrop in the background, ahead of opening.
    @State private var isPreloadingBackdrop = false
    @State private var expandTask: Task<Void, Never>?
    /// Absent whenever a card is used outside a shelf — a grid, a detail page —
    /// where there is no row of neighbours to stand aside and the card simply
    /// opens over whatever is beside it.
    @Environment(ShelfExpansion.self) private var shelfExpansion: ShelfExpansion?
    @Environment(\.shelfSlot) private var shelfSlot: Int?
    /// Whether the pointer is over this card's place in the row, which is not
    /// the same question as whether the card is open.
    @State private var isPointerInside = false

    private var isRowScrolling: Bool { shelfExpansion?.isScrolling ?? false }

    /// How long the pointer has to stay put before the card opens. Short
    /// enough to feel like the card answering the pointer rather than a wait,
    /// long enough that a pointer crossing the shelf on its way somewhere else
    /// doesn't open every card it passes over.
    private static let hoverExpandDelay: Double = 0.7

    /// The backdrop starts loading before the card opens, but not on the very
    /// first instant of hover: sweeping a pointer across a shelf touches a
    /// dozen cards in a second, and fetching and decoding a full-size backdrop
    /// for each of them is what made a fast scroll beachball. A pointer that
    /// stays this long is on the card on purpose, and the head start means the
    /// backdrop is decoded by the time it is asked to appear.
    private static let backdropPreloadDelay: Double = 0.2
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
        #if os(macOS)
        // A LazyHStack draws its children in order, so without this the cards
        // further along the shelf paint over the widened one and it reads as
        // sliding underneath them.
        .zIndex(isExpanded ? 1 : 0)
        #endif
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
        isExpanded ? landscapeWidth : width
        #else
        width
        #endif
    }

    /// The slot the card occupies in the shelf, and — on the Mac — the whole of
    /// what the pointer answers to.
    ///
    /// The opened card is drawn *over* the shelf rather than inside it: the slot
    /// keeps the poster's width whatever the artwork is doing, and the widened
    /// plate is an overlay that spills out of it. Growing the slot instead moved
    /// every card after this one — and the scroll view realigned itself to the
    /// new geometry — all while the pointer stood still, which is how a card two
    /// along ended up under a pointer that had not left this one.
    ///
    /// The pointer belongs to the slot, not to the plate: a card is hovered
    /// while the pointer is over the poster's own place in the row, and opening
    /// does not enlarge that. So the region that decides hovering is a fixed
    /// rectangle that never moves and never resizes — leave the poster's place
    /// and the card closes, whatever it happened to be drawing over at the time.
    /// The plate takes no pointer at all, so it can never stand between the
    /// pointer and the card underneath it.
    private var poster: some View {
        #if os(macOS)
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) { artworkPlate.allowsHitTesting(false) }
            .onHover { hovering in
                isPointerInside = hovering
                // A row in motion answers to the scroll, not to the cards it
                // is carrying past the pointer.
                guard !isRowScrolling else { return }
                if hovering { beginOpening() } else { closeNow() }
            }
            .onChange(of: isRowScrolling) { _, scrolling in
                if scrolling {
                    // Whatever is open stays open and travels with the row —
                    // collapsing a card the moment a scroll begins is the
                    // flicker this is here to avoid — but nothing new opens.
                    expandTask?.cancel()
                } else {
                    // Come to rest as a row of posters, then let wherever the
                    // pointer actually ended up open on its own terms.
                    closeNow()
                    if isPointerInside { beginOpening() }
                }
            }
            .onDisappear {
                // A card scrolled out of the row must not open behind the
                // pointer, and must not leave the row holding room for a card
                // that is no longer in it.
                isPointerInside = false
                closeNow()
            }
        #else
        artworkPlate
        #endif
    }

    /// Starts the wait that opens the card: the backdrop loads first, and the
    /// card turns over once the pointer has stayed long enough to mean it.
    private func beginOpening() {
        // Asked for now, not when the card opens: the fetch and the backdrop
        // then have the whole wait to arrive, and the card opens complete.
        SynopsisCache.shared.fetchIfNeeded(for: item, addonBaseURL: addonBaseURL)
        expandTask?.cancel()
        expandTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.backdropPreloadDelay))
            guard !Task.isCancelled else { return }
            isPreloadingBackdrop = true

            try? await Task.sleep(
                for: .seconds(Self.hoverExpandDelay - Self.backdropPreloadDelay)
            )
            guard !Task.isCancelled else { return }
            isExpanded = true
            // Ask the cards after this one to stand aside by exactly the width
            // this one is about to spill over them.
            if let shelfSlot {
                shelfExpansion?.open(slot: shelfSlot, extraWidth: landscapeWidth - width)
            }
        }
    }

    /// Back to a poster at once. The delay is there to make opening
    /// deliberate, not to make a row slow to recover.
    private func closeNow() {
        expandTask?.cancel()
        expandTask = nil
        isExpanded = false
        isPreloadingBackdrop = false
        if let shelfSlot { shelfExpansion?.close(slot: shelfSlot) }
    }

    /// The artwork itself, at whatever width it is currently drawn.
    private var artworkPlate: some View {
        artwork
        .frame(width: artworkWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Phone.posterRadius, style: .continuous))
        #if os(macOS)
        .overlay { synopsis }
        #endif
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
        .animation(.easeInOut(duration: 0.42), value: isExpanded)
        #endif
    }

    #if os(macOS)
    /// What the title is about, across the foot of the opened card.
    ///
    /// Only once the card is open: a poster is too narrow to hold a sentence,
    /// and the backdrop is the moment there is room for one. It sits in the
    /// leading half so it never runs under the rating badge in the opposite
    /// corner, over a wash dark enough to read on artwork of any brightness.
    @ViewBuilder
    private var synopsis: some View {
        if isExpanded,
           let text = SynopsisCache.shared.synopsis(for: item, addonBaseURL: addonBaseURL) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: artworkWidth * 0.62, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
            // Clipped to the card's own corners: the wash is a part of the
            // artwork, not a panel laid over it.
            .clipShape(RoundedRectangle(cornerRadius: Phone.posterRadius, style: .continuous))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
    #endif

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

            // Built only once the pointer has settled on this card. Holding a
            // second full-size image for every card in every shelf meant a fast
            // scroll kicked off a backdrop fetch and decode per card it built —
            // enough of them at once to stall the app. The load starts ahead of
            // the card opening, so it is still decoded by the time it is asked
            // to appear.
            if isPreloadingBackdrop, let backdropURL {
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
    private var isShowingBackdrop: Bool { isExpanded && backdropURL != nil }
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

    #if os(macOS)
    /// Which card in *this* shelf is open, and how much room it needs. One per
    /// shelf, so opening a card in one row never moves another row.
    @State private var expansion = ShelfExpansion()
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title, subtitle: subtitle, onSeeAll: onSeeAll)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: isRanked ? 2 : Phone.posterSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        card(item, offset)
                        #if os(macOS)
                            // The cards after the open one stand aside to make
                            // the room it spills into, and slide back the
                            // moment it closes.
                            .standingAside(for: expansion, slot: offset)
                        #endif
                    }
                }
                .padding(.horizontal, Phone.pagePadding)
                .scrollTargetLayout()
                #if os(macOS)
                .environment(expansion)
                #endif
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            #if os(macOS)
            .onScrollPhaseChange { _, phase in
                expansion.isScrolling = phase != .idle
            }
            #endif
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
