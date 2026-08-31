import SwiftUI

// The television's hero treatment: a Ken Burns backdrop carousel with its own
// focusable controls, plus the skeleton that holds its space while the first
// catalog loads.
//
// The phone shell's `Billboard` is the same idea built for a thumb; on a
// ten-foot screen the artwork is the whole point, so `BrowseScreen` draws this
// instead. Everything else that used to live here — the shelves, the poster
// cards, the filter bar — is now shared with iOS and lives in
// `PhoneComponents` and `BrowseScreen`.
#if os(tvOS)

/// A rotating showcase of a handful of titles, each with its backdrop, title
/// treatment and a one-line pitch — the opening shot of every streaming app.
struct HeroCarousel: View {
    let items: [HeroItem]
    let metrics: LayoutMetrics
    let onSelect: (HeroItem) -> Void

    /// The hero's own controls, so the carousel can tell when the viewer is
    /// acting on the current title.
    private enum Control: Hashable { case play, details, myList, next }

    /// A title whose sources are ready to be shown.
    private struct PlayTarget: Identifiable {
        let selection: MetaSelection
        let detail: MetaDetail

        var id: String { "\(selection.item.type)|\(selection.item.id)" }
    }

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.palette) private var palette
    @State private var index = 0
    @State private var playTarget: PlayTarget?
    @State private var isPreparingPlay = false
    @FocusState private var focusedControl: Control?

    /// How many seconds each title holds the screen before the carousel moves
    /// on, and how often the rotation checks in.
    private static let dwellSeconds = 9

    private var current: HeroItem { items[min(index, items.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            scrims
            content

            // Centred under the frame rather than tucked under the copy: the
            // dots describe the whole hero, not the column of type.
            if items.count > 1 {
                PageDots(count: items.count, index: index)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, metrics.lerp(14, 34))
            }
        }
        .frame(height: metrics.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: items.count) { await autoAdvance() }
        // Play goes straight to the sources, the way the primary control on
        // every streaming home screen does. The meta is fetched first because
        // a series has to open on its episodes, not on the series id.
        .fullScreenCover(item: $playTarget) { target in
            StreamPicker(selection: target.selection, detail: target.detail)
        }
    }

    // MARK: Layers

    private var backdrop: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, hero in
                if offset == index {
                    KenBurnsImage(
                        url: AddonClient.resolve(
                            hero.item.background ?? hero.item.poster,
                            relativeTo: hero.addonBaseURL
                        )
                    )
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.9), value: index)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Three layers, in the order a colourist would grade them: a light top
    /// wash for the chrome, a long bottom ramp that carries the artwork into
    /// the app background, and a soft left-hand falloff under the copy.
    ///
    /// The ramps are deliberately late and deliberately gradual. The earlier
    /// pass darkened the middle of the frame, which is exactly where the
    /// picture is — the backdrop read as a grey plate rather than as a still
    /// from the film.
    private var scrims: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.18), location: 0.14),
                    .init(color: .clear, location: 0.34),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.30),
                    .init(color: .black.opacity(0.30), location: 0.52),
                    .init(color: .black.opacity(0.72), location: 0.72),
                    .init(color: palette.background.opacity(0.97), location: 0.90),
                    .init(color: palette.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.78), location: 0),
                    .init(color: .black.opacity(0.34), location: 0.34),
                    .init(color: .clear, location: 0.66),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: metrics.lerp(10, 16)) {
            typeBadge

            HeroTitleTreatment(hero: current, metrics: metrics)

            Text("Now Streaming")
                .font(.system(size: metrics.lerp(15, 27), weight: .bold))
                .foregroundStyle(.white)
                .overArtwork()

            HeroFacts(item: current.item, metrics: metrics)

            if let synopsis = current.item.description?.trimmed, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: metrics.lerp(14, 24), weight: .regular))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
                    .lineSpacing(metrics.lerp(4, 7))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .overArtwork()
            }

            controls
                .padding(.top, metrics.lerp(4, 12))
        }
        .frame(width: metrics.heroContentWidth, alignment: .leading)
        .padding(.horizontal, metrics.pagePadding)
        .padding(.bottom, metrics.lerp(30, 108))
        .animation(.easeInOut(duration: 0.45), value: index)
    }

    /// The small light pill over the title treatment — what kind of thing this
    /// is, before the logo says which one.
    private var typeBadge: some View {
        Text(HomeViewModel.typeLabel(current.item.type).uppercased())
            .font(.system(size: metrics.lerp(11, 16), weight: .heavy))
            .tracking(metrics.lerp(0.8, 1.4))
            .foregroundStyle(.black)
            .padding(.horizontal, metrics.lerp(9, 14))
            .padding(.vertical, metrics.lerp(4, 7))
            .background(Capsule().fill(.white))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    /// One Play, and the rest kept deliberately quiet beside it. The row has
    /// to read as a single call to action across a room, so the two secondary
    /// controls carry their icon only and no label.
    private var controls: some View {
        HStack(spacing: metrics.lerp(10, 18)) {
            Button {
                Task { await preparePlay() }
            } label: {
                Text(isPreparingPlay ? "Loading…" : "Play")
            }
            .buttonStyle(
                NuvioButtonStyle(kind: .prominent, icon: "play.fill", compact: metrics.isCompact)
            )
            .disabled(isPreparingPlay)
            .focused($focusedControl, equals: .play)

            HeroIconButton(
                systemImage: library.contains(current.item) ? "checkmark" : "plus",
                label: library.contains(current.item) ? "In My List" : "Add to My List",
                metrics: metrics
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    library.toggle(current.item, addonBaseURL: current.addonBaseURL)
                }
            }
            .focused($focusedControl, equals: .myList)

            HeroIconButton(
                systemImage: "info.circle.fill",
                label: "Details",
                metrics: metrics
            ) {
                onSelect(current)
            }
            .focused($focusedControl, equals: .details)

            if items.count > 1 {
                HeroIconButton(
                    systemImage: "forward.fill",
                    label: "Next title",
                    metrics: metrics
                ) {
                    advance()
                }
                .focused($focusedControl, equals: .next)
            }
        }
    }

    // MARK: Play

    /// Fetches the title's meta, then opens the source picker on it. A series
    /// needs its season list to land on the episode step rather than asking
    /// the addons for streams of the series itself; if the fetch fails, the
    /// press falls back to opening the title's own page.
    private func preparePlay() async {
        guard !isPreparingPlay else { return }
        let hero = current
        isPreparingPlay = true
        defer { isPreparingPlay = false }

        let selection = MetaSelection(item: hero.item, addonBaseURL: hero.addonBaseURL)
        let detail = try? await AddonClient().meta(
            baseURL: hero.addonBaseURL,
            type: hero.item.type,
            id: hero.item.id
        )

        guard let detail else {
            onSelect(hero)
            return
        }
        playTarget = PlayTarget(selection: selection, detail: detail)
    }

    // MARK: Rotation

    private func advance() {
        withAnimation(.easeInOut(duration: 0.7)) {
            index = (index + 1) % max(items.count, 1)
        }
    }

    /// Rotates on a timer, but holds the current title for as long as the
    /// viewer has one of its controls focused — nothing is worse than the
    /// backdrop changing just as you press select.
    private func autoAdvance() async {
        guard items.count > 1 else { return }
        var held = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            if focusedControl != nil {
                held = 0
                continue
            }

            held += 1
            if held >= Self.dwellSeconds {
                held = 0
                advance()
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

/// A hero control that carries its icon only, so the row still reads as one
/// Play button from across a room. It keeps a full accessibility label, since
/// what a glyph means is not obvious to VoiceOver.
private struct HeroIconButton: View {
    let systemImage: String
    let label: String
    let metrics: LayoutMetrics
    let action: () -> Void

    private var diameter: CGFloat { metrics.lerp(38, 66) }

    var body: some View {
        Button(action: action) {
            FocusReader { isFocused in
                Image(systemName: systemImage)
                    .font(.system(size: metrics.lerp(15, 25), weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .frame(width: diameter, height: diameter)
                    .background {
                        Circle().fill(
                            isFocused
                                ? AnyShapeStyle(Color.white)
                                : AnyShapeStyle(Color.white.opacity(0.16))
                        )
                    }
                    .overlay {
                        Circle().strokeBorder(.white.opacity(isFocused ? 0 : 0.24), lineWidth: 1)
                    }
                    .scaleEffect(isFocused ? 1.1 : 1)
                    .shadow(color: .black.opacity(0.5), radius: isFocused ? 20 : 8, y: isFocused ? 8 : 4)
                    .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isFocused)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Carousel position, drawn as the widening pill every streaming app uses.
private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { position in
                Capsule()
                    .fill(.white.opacity(position == index ? 0.9 : 0.25))
                    .frame(width: position == index ? 26 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
    }
}

/// Holds the hero's space while the first catalogs are still in flight.
private struct HeroSkeleton: View {
    let metrics: LayoutMetrics
    let isLoading: Bool
    let error: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SkeletonBlock(cornerRadius: 0)
                .opacity(isLoading ? 1 : 0.35)

            VStack(alignment: .leading, spacing: 18) {
                if let error, !isLoading {
                    Text(error)
                        .font(.system(size: metrics.lerp(16, 26), weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SkeletonBlock(cornerRadius: 10)
                        .frame(width: metrics.lerp(200, 460), height: metrics.lerp(30, 62))
                    SkeletonBlock(cornerRadius: 8)
                        .frame(width: metrics.lerp(260, 640), height: metrics.lerp(14, 24))
                }
            }
            .frame(width: metrics.heroContentWidth, alignment: .leading)
            .padding(.horizontal, metrics.pagePadding)
            .padding(.bottom, metrics.lerp(26, 64))
        }
        .frame(height: metrics.heroHeight)
    }
}
#endif
