import SwiftUI

// The television's hero, in the shape Peacock's 2022 TV redesign gave it: a
// stage at the top of Home, full-bleed key art — or the title's trailer —
// with the logo, a line of facts, the synopsis and its Details / My List
// buttons set bottom-left. It is a carousel of its own: it fills the first
// screenful, leaving only the top of the next row peeking beneath it, and
// the shelves take focus once the viewer moves down.
//
// The phone shell's `Billboard` is the same idea built for a thumb.
#if os(tvOS)

/// The title the viewer's focus is on, for the hero above the shelves.
///
/// There is one hero. Cards don't play anything themselves; they say "this is
/// where focus is" and the hero swaps its artwork, copy and trailer to match.
@Observable
@MainActor
final class HeroFocus {
    /// A title card has focus. `nil` until one has been focused; the hero
    /// rotates on its own until then.
    private(set) var item: HeroItem?
    /// A collection tile has focus — the hero shows that collection's header.
    private(set) var collection: CollectionHero?
    /// The row that card belongs to, so the page can scroll that row into place.
    private(set) var row: String?

    func focus(_ hero: HeroItem, row: String?) {
        if hero != item { item = hero }
        if collection != nil { collection = nil }
        if row != self.row { self.row = row }
    }

    func focus(collection: CollectionHero, row: String?) {
        if collection != self.collection { self.collection = collection }
        if row != self.row { self.row = row }
    }
}

/// What a collection tile shows the hero: the same header its own page opens
/// with — backdrop (or the author's animation), then the logo or the name.
struct CollectionHero: Equatable {
    let id: String
    let title: String
    let collectionTitle: String
    let backdropURL: URL?
    let animatedURL: URL?
    let logoURL: URL?
    /// The folder's own hero video, if its author attached one.
    let videoURL: URL?

    init(folder: CollectionFolder, collection: MediaCollection) {
        id = "\(collection.id)|\(folder.id)"
        title = folder.title
        collectionTitle = collection.title
        backdropURL = (folder.heroBackdropURL ?? collection.backdropImageURL).flatMap(URL.init(string:))
            ?? folder.coverImageURL.flatMap(URL.init(string:))
        animatedURL = folder.animatedCoverURL
        logoURL = folder.titleLogoURL.flatMap(URL.init(string:))
        videoURL = folder.heroVideoURL.flatMap(URL.init(string:))
    }
}

struct HomeHero: View {
    let items: [HeroItem]
    let metrics: LayoutMetrics
    /// Opens a title's detail page.
    let onOpen: (HeroItem) -> Void
    /// Focus came back to the hero, so the page should scroll back up to it.
    let onFocus: () -> Void
    /// The screen's focus scope, so Details can be its preferred landing.
    let focusSpace: Namespace.ID

    private enum Control { case entry, details, list }
    @FocusState private var focusedControl: Control?
    @EnvironmentObject private var library: LibraryStore
    /// How much of the hero is on screen; a trailer off screen is paused.
    @State private var isVisible = true

    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tmdb: TmdbSettings

    @State private var index = 0
    /// The trailer is on screen. The rotation holds still while it is.
    @State private var isTrailerPlaying = false

    /// How much of the next row shows under the hero: its title and the top
    /// of its cards, enough to say "there is more below".
    private static let peek: CGFloat = 170

    /// How many seconds each title holds the stage before it rotates on.
    private static let dwellSeconds = 9

    /// The hero is a carousel: it pages through the featured titles on its
    /// own, whatever the shelves below have focus on.
    private var current: HeroItem { items[min(index, items.count - 1)] }

    var body: some View {
        content
            // The first screenful, less a strip that lets the next row peek in.
            .containerRelativeFrame(.vertical, alignment: .bottomLeading) { length, _ in
                length - Self.peek
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            // The whole stage is one focus target, so moving down from the
            // tab bar lands on its buttons rather than on whichever card
            // happens to sit nearest underneath.
            .focusSection()
            // Coming down from the tab bar lands here, not on a card.
            .defaultFocus($focusedControl, .details)
            // The artwork runs to the edges of the screen; only the copy stays
            // inside the television's safe area. It is a background so that
            // reaching past the safe area adds nothing to the hero's own height.
            .background(alignment: .bottom) {
                ZStack {
                    palette.background
                    backdrop
                    scrims
                }
                // Fades out into the page rather than ending on an edge: the
                // scrims darken the left side all the way down, so where the
                // hero stopped there was a visible step from near-black to the
                // page colour.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.72),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea(edges: [.top, .horizontal])
            }
            .overlay(alignment: .bottomTrailing) { soundBadge }
            .overlay(alignment: .bottomLeading) { pageDots }
            .overlay(alignment: .top) { entryTarget }
            .onScrollVisibilityChange(threshold: 0.3) { isVisible = $0 }
            .onChange(of: focusedControl) { _, control in
                if control != nil { onFocus() }
            }
            .task(id: items.count) { await autoAdvance() }
    }

    /// An invisible, full-width focus target just under the tab bar. Moving
    /// down from the bar picks the nearest focusable thing below it, which
    /// would otherwise be a card in the first row, past the stage's buttons;
    /// this is nearer, and hands focus straight to Details. It steps out of
    /// the way while a button holds focus so up still reaches the bar.
    private var entryTarget: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .padding(.top, 140)
            .focusable(focusedControl == nil || focusedControl == .entry)
            .focused($focusedControl, equals: .entry)
            .onChange(of: focusedControl) { _, control in
                if control == .entry { focusedControl = .details }
            }
            .accessibilityHidden(true)
    }

    /// Where the carousel is, one dot per featured title.
    @ViewBuilder
    private var pageDots: some View {
        if items.count > 1 {
            HStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(i == index ? 0.95 : 0.35))
                        .frame(width: i == index ? 22 : 8, height: 8)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: index)
            .padding(.horizontal, metrics.pagePadding)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
        }
    }

    /// Which way the sound is set, shown only while a trailer is on screen.
    /// Play/Pause on the remote flips it.
    @ViewBuilder
    private var soundBadge: some View {
        if isTrailerPlaying {
            Image(systemName: tmdb.trailerSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: metrics.lerp(14, 24), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: metrics.lerp(30, 56), height: metrics.lerp(30, 56))
                .glassEffect(.regular, in: .circle)
                .padding(.trailing, metrics.pagePadding)
                .padding(.bottom, metrics.lerp(24, 44))
                .transition(.opacity)
                .accessibilityLabel(tmdb.trailerSound ? "Trailer sound on" : "Trailer sound off")
        }
    }

    // MARK: Layers

    /// The picture sits on the right at its natural 16:9, as tall as the
    /// stage, and fades in across its left edge into the panel the copy is
    /// set on — Peacock's arrangement. Filling the whole width instead crops a
    /// 16:9 frame to a thin band, which loses the picture and puts a
    /// trailer's own lettering behind the title.
    private var backdrop: some View {
        GeometryReader { geo in
            // A little taller than the stage, hanging off the top of the
            // screen: the stage's own height stopped 16 points short of it.
            let height = geo.size.height + 60
            let width = height * 16 / 9

            ZStack {
                KenBurnsImage(
                    url: AddonClient.resolve(
                        current.item.background ?? current.item.poster,
                        relativeTo: current.addonBaseURL
                    )
                )
                .id(current.id)
                .transition(.opacity)

                // The trailer, over the still. It starts a beat after the
                // title takes the stage, and fades in once it has a frame, so
                // a slow lookup never shows a black one.
                FocusTrailerPreview(
                    item: current.item,
                    isActive: scenePhase == .active && isVisible,
                    delay: .milliseconds(700),
                    onPlayingChange: { isTrailerPlaying = $0 },
                    // When the trailer ends the title gets a few more seconds
                    // on stage, then the carousel moves on. A focused button,
                    // or a change of title in the meantime, cancels it.
                    onFinish: {
                        let finished = current.id
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            guard focusedControl == nil, current.id == finished else { return }
                            withAnimation(.easeInOut(duration: 0.7)) {
                                index = (index + 1) % items.count
                            }
                        }
                    }
                )
                .id(current.id)
                .aspectRatio(16 / 9, contentMode: .fill)
                // Many trailers carry their own letterbox bars, and some a
                // title card in them; drawn as they are, the bars read as a
                // hard edge across the stage. A little zoom lets the stage's
                // own clip take most of them off.
                .scaleEffect(1.2)
            }
            .animation(.easeInOut(duration: 0.5), value: current.id)
            .frame(width: width, height: height)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.55), location: 0.16),
                        .init(color: .black, location: 0.42),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
        }
    }

    /// A light wash under the tab bar, a ramp that carries the artwork down
    /// into the page, and a soft falloff on the left under the copy.
    private var scrims: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.18), location: 0.16),
                    .init(color: .clear, location: 0.36),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.34),
                    .init(color: .black.opacity(0.40), location: 0.62),
                    .init(color: .black.opacity(0.78), location: 0.82),
                    .init(color: palette.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.5),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        titleContent
    }

    /// A collection's header: its logo, or its name set large, over the name
    /// of the shelf it belongs to.
    private func collectionContent(_ collection: CollectionHero) -> some View {
        VStack(alignment: .leading, spacing: metrics.lerp(10, 16)) {
            Group {
                if let logo = collection.logoURL {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(
                            maxWidth: metrics.heroLogoMaxWidth,
                            maxHeight: metrics.heroLogoMaxHeight,
                            alignment: .leading
                        )
                } else {
                    Text(collection.title)
                        .font(.system(size: metrics.heroTitleSize, weight: .black))
                        .tracking(metrics.heroTitleSize * -0.022)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overArtwork()

            Text("COLLECTION  ·  \(collection.collectionTitle.uppercased())")
                .font(.system(size: metrics.lerp(12, 19), weight: .semibold))
                .tracking(metrics.lerp(0.8, 1.6))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .overArtwork()
        }
        .frame(width: metrics.heroContentWidth, alignment: .leading)
        .padding(.horizontal, metrics.pagePadding)
        .padding(.bottom, metrics.lerp(24, 44))
        .animation(.easeInOut(duration: 0.4), value: collection.id)
    }

    private var titleContent: some View {
        VStack(alignment: .leading, spacing: metrics.lerp(10, 16)) {
            HeroTitleTreatment(hero: current, metrics: metrics)

            HeroFacts(item: current.item, metrics: metrics)

            if let synopsis = current.item.description?.trimmed, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: metrics.lerp(14, 24), weight: .regular))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
                    .lineSpacing(metrics.lerp(4, 7))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .overArtwork()
            }

            controls
        }
        .frame(width: metrics.heroContentWidth, alignment: .leading)
        .padding(.horizontal, metrics.pagePadding)
        // Clears the dots, and keeps the buttons inside the television's
        // safe area.
        .padding(.bottom, metrics.lerp(24, 44) + 28)
        .animation(.easeInOut(duration: 0.4), value: current.id)
    }

    /// What the carousel's current title offers: its page, and the list.
    /// Left on the first button and right on the last page the carousel.
    private var controls: some View {
        HStack(spacing: 20) {
            Button {
                onOpen(current)
            } label: {
                Label("Details", systemImage: "info.circle.fill")
            }
            .buttonStyle(HeroButtonStyle())
            .focused($focusedControl, equals: .details)
            .prefersDefaultFocus(true, in: focusSpace)
            .onMoveCommand { if $0 == .left { step(-1) } }

            Button {
                library.toggle(current.item, addonBaseURL: current.addonBaseURL)
            } label: {
                if library.contains(current.item) {
                    Label("In My List", systemImage: "checkmark")
                } else {
                    Label("My List", systemImage: "plus")
                }
            }
            .buttonStyle(HeroButtonStyle())
            .focused($focusedControl, equals: .list)
            .onMoveCommand { if $0 == .right { step(1) } }
        }
        .padding(.top, 8)
    }

    private func step(_ by: Int) {
        guard items.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            index = (index + by + items.count) % items.count
        }
    }

    // MARK: Rotation

    /// Rotates on a timer and holds still while a trailer plays or a button
    /// on the stage has focus.
    private func autoAdvance() async {
        guard items.count > 1 else { return }
        var held = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            if isTrailerPlaying || focusedControl != nil {
                held = 0
                continue
            }

            held += 1
            if held >= Self.dwellSeconds {
                held = 0
                withAnimation(.easeInOut(duration: 0.7)) {
                    index = (index + 1) % items.count
                }
            }
        }
    }
}

/// The hero's buttons: a quiet glass pill at rest, and a solid white one only
/// while it holds focus, so exactly one of the pair ever reads as selected.
private struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.2))
                )
                .scaleEffect(isFocused ? 1.08 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// A collection's header artwork: its still backdrop, with the author's
/// animation over it once that has frames — otherwise the stage would blink
/// to empty first.
private struct CollectionBackdrop: View {
    let collection: CollectionHero
    let size: CGSize

    @State private var animationReady = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            KenBurnsImage(url: collection.backdropURL)

            // The hero video plays once over the backdrop and then fades back
            // to it. A folder that has one doesn't also loop its cover
            // animation, which would put it back over the still afterwards.
            if let video = collection.videoURL {
                FocusTrailerPreview(
                    directURL: video,
                    isActive: scenePhase == .active,
                    delay: .milliseconds(600)
                )
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
            } else if let animation = collection.animatedURL {
                AnimatedImage(
                    url: animation,
                    maxPixelSize: max(size.width, size.height),
                    isPlaying: true,
                    onReady: { ready in
                        withAnimation(.easeOut(duration: 0.3)) { animationReady = ready }
                    }
                )
                .frame(width: size.width, height: size.height)
                .clipped()
                .opacity(animationReady ? 1 : 0)
            }
        }
    }
}

/// The backdrop, drifting slowly. The movement is small on purpose — enough
/// to feel alive on a big screen, not enough to distract.
private struct KenBurnsImage: View {
    let url: URL?
    @State private var zoomed = false

    var body: some View {
        RemoteImage(url: url) {
            AnyView(Color.white.opacity(0.04))
        }
        .scaleEffect(zoomed ? 1.12 : 1.03)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 14)) { zoomed = true }
        }
    }
}

/// A title's logo artwork if the addon has one, its name set large if not.
private struct HeroTitleTreatment: View {
    let hero: HeroItem
    let metrics: LayoutMetrics

    @State private var logoFailed = false

    private var logoURL: URL? {
        guard !logoFailed, let logo = hero.item.logo?.trimmed, !logo.isEmpty else { return nil }
        return AddonClient.resolve(logo, relativeTo: hero.addonBaseURL)
    }

    var body: some View {
        Group {
            if let logoURL {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: metrics.heroLogoMaxWidth,
                                maxHeight: metrics.heroLogoMaxHeight,
                                alignment: .leading
                            )
                    case .failure:
                        typeset.onAppear { logoFailed = true }
                    default:
                        typeset
                    }
                }
            } else {
                typeset
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overArtwork()
        .id(hero.id)
        .transition(.opacity)
    }

    private var typeset: some View {
        Text(hero.item.name)
            .font(.system(size: metrics.heroTitleSize, weight: .black))
            .tracking(metrics.heroTitleSize * -0.022)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The facts line under a hero title: type, year, rating, a genre or two.
///
/// Set as one dot-separated caption rather than a row of filled chips. Chips
/// are controls, and nothing here is selectable — on a television a line of
/// them reads as a toolbar the viewer keeps trying to focus.
private struct HeroFacts: View {
    let item: MetaItem
    let metrics: LayoutMetrics

    private var facts: [String] {
        var parts = [HomeViewModel.typeLabel(item.type)]
        if let year = item.releaseInfo?.trimmed, !year.isEmpty { parts.append(year) }
        parts.append(contentsOf: item.genres.prefix(Int(metrics.lerp(1, 2).rounded())))
        return parts
    }

    var body: some View {
        HStack(spacing: metrics.lerp(8, 14)) {
            if let rating = item.imdbRating?.trimmed, !rating.isEmpty {
                HStack(spacing: metrics.lerp(4, 6)) {
                    Image(systemName: "star.fill")
                        .font(.system(size: metrics.lerp(11, 17), weight: .bold))
                        .foregroundStyle(NuvioPalette.rgb(0xF5C518))
                    Text(rating)
                        .font(.system(size: metrics.lerp(12, 19), weight: .bold))
                        .foregroundStyle(.white)
                }
                separator
            }

            ForEach(Array(facts.enumerated()), id: \.offset) { offset, fact in
                if offset > 0 { separator }
                Text(fact.uppercased())
                    .font(.system(size: metrics.lerp(12, 19), weight: .semibold))
                    .tracking(metrics.lerp(0.8, 1.6))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .lineLimit(1)
        .overArtwork()
    }

    private var separator: some View {
        Circle()
            .fill(.white.opacity(0.4))
            .frame(width: metrics.lerp(3, 5), height: metrics.lerp(3, 5))
    }
}

#endif
