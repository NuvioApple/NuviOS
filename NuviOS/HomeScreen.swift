import SwiftUI

// The TV home screen. Laid out in TV metrics and driven by the focus
// engine, so it never compiles into the phone shell — `RootView` and
// `BrowseScreen` are the iOS equivalents.
#if os(tvOS)

/// The browsing screen: a cinematic hero carousel over one focusable shelf per
/// catalog the user's addons publish, backed by the Stremio addon protocol.
struct HomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var profiles: ProfileStore
    @StateObject private var model = HomeViewModel()

    @State private var selected: MetaSelection?
    @State private var openFolder: OpenFolder?
    @State private var showingSettings = false
    @State private var typeFilter: String?

    let subtitle: String

    private var visibleRows: [CatalogRow] { model.rows(matching: typeFilter) }

    var body: some View {
        GeometryReader { proxy in
            let metrics = LayoutMetrics(width: proxy.size.width, height: proxy.size.height)

            ZStack {
                NuvioBackground(intensity: 0.85)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        masthead(metrics)

                        if !model.availableTypes.isEmpty {
                            FilterBar(
                                types: model.availableTypes,
                                selection: $typeFilter,
                                metrics: metrics
                            )
                            .padding(.top, metrics.lerp(18, 30))
                            .padding(.bottom, metrics.lerp(4, 10))
                        }

                        shelves(metrics)
                    }
                    .padding(.bottom, metrics.lerp(40, 90))
                }
                .scrollClipDisabled()
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.loadIfNeeded(session: session, profile: profiles.current) }
        .fullScreenCover(item: $openFolder) { open in
            FolderView(open: open, addons: model.addons)
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
        .fullScreenCover(item: $selected) { selection in
            MetaDetailView(selection: selection)
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
        .fullScreenCover(isPresented: $showingSettings) {
            SettingsView(
                subtitle: subtitle,
                isRefreshing: model.isLoading,
                onRefresh: { Task { await model.refresh(session: session, profile: profiles.current) } }
            )
            .environmentObject(theme)
            .environment(\.palette, theme.palette)
        }
    }

    // MARK: Masthead

    /// The hero carousel with the app chrome laid over it. When there's no
    /// artwork to show yet, the same space becomes a skeleton so the screen
    /// doesn't reflow the moment the first catalog lands.
    @ViewBuilder
    private func masthead(_ metrics: LayoutMetrics) -> some View {
        ZStack(alignment: .top) {
            if model.heroItems.isEmpty {
                HeroSkeleton(metrics: metrics, isLoading: model.isLoading, error: model.loadError)
            } else {
                HeroCarousel(items: model.heroItems, metrics: metrics) { hero in
                    selected = MetaSelection(item: hero.item, addonBaseURL: hero.addonBaseURL)
                }
            }

            TopBar(metrics: metrics) { showingSettings = true }
        }
        .frame(height: metrics.heroHeight)
    }

    // MARK: Shelves

    @ViewBuilder
    private func shelves(_ metrics: LayoutMetrics) -> some View {
        if model.rows.isEmpty, model.isLoading {
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                ForEach(0..<2, id: \.self) { _ in
                    ShelfSkeleton(metrics: metrics)
                }
            }
            .padding(.top, metrics.rowSpacing)
        } else if let error = model.loadError, model.rows.isEmpty {
            EmptyStateCard(message: error, metrics: metrics) {
                Task { await model.refresh(session: session, profile: profiles.current) }
            }
            .padding(.horizontal, metrics.pagePadding)
            .padding(.top, metrics.rowSpacing)
        } else {
            LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                // The user's own shelves lead, ahead of the addons' catalogs.
                // They only belong on the unfiltered view: a collection isn't
                // a content type.
                if typeFilter == nil {
                    ForEach(model.collections) { collection in
                        CollectionShelfView(collection: collection, metrics: metrics) { folder in
                            openFolder = OpenFolder(
                                collectionID: collection.id,
                                collectionTitle: collection.title,
                                folder: folder,
                                showAllTab: collection.showAllTab,
                                backdropURL: collection.backdropImageURL
                            )
                        }
                    }
                }

                ForEach(visibleRows) { row in
                    CatalogRowView(row: row, metrics: metrics) { item in
                        selected = MetaSelection(item: item, addonBaseURL: row.addonBaseURL)
                    }
                }
            }
            .padding(.top, metrics.lerp(18, 24))
        }
    }
}

// MARK: - Chrome

/// The bar that floats over the hero: wordmark on the left, account and
/// settings on the right. It scrolls away with the hero, the way the Apple TV
/// app's own header does.
private struct TopBar: View {
    let metrics: LayoutMetrics
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Wordmark(size: metrics.wordmarkSize)
                .overArtwork()

            Spacer(minLength: 20)

            Button(action: onSettings) {
                Text("Settings")
            }
            .buttonStyle(NuvioButtonStyle(kind: .glass, icon: "gearshape.fill", compact: true))
        }
        .padding(.horizontal, metrics.pagePadding)
        .padding(.top, metrics.lerp(8, 20))
        .frame(height: metrics.topBarHeight, alignment: .center)
    }
}

/// Type tabs across the top of the shelves. Only ever offers types the loaded
/// catalogs actually contain.
private struct FilterBar: View {
    let types: [String]
    @Binding var selection: String?
    let metrics: LayoutMetrics

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: metrics.lerp(10, 16)) {
                tab(title: "All", value: nil)
                ForEach(types, id: \.self) { type in
                    tab(title: HomeViewModel.typeLabel(type), value: type)
                }
            }
            .padding(.horizontal, metrics.pagePadding)
            .padding(.vertical, metrics.lerp(4, 16))
        }
        .scrollClipDisabled()
    }

    private func tab(title: String, value: String?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selection = value }
        } label: {
            Text(title)
        }
        .buttonStyle(
            FilterTabStyle(isSelected: selection == value, compact: metrics.isCompact)
        )
    }
}

private struct FilterTabStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    let isSelected: Bool
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            configuration.label
                .font(.system(size: compact ? 15 : 24, weight: .semibold))
                .foregroundStyle(foreground(isFocused))
                .padding(.horizontal, compact ? 16 : 28)
                .padding(.vertical, compact ? 8 : 12)
                .background {
                    Capsule().fill(background(isFocused))
                }
                .overlay {
                    Capsule().strokeBorder(
                        isFocused ? Color.white : Color.white.opacity(isSelected ? 0 : 0.14),
                        lineWidth: isFocused ? 2 : 1
                    )
                }
                .scaleEffect(isFocused ? 1.08 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
    }

    private func foreground(_ isFocused: Bool) -> Color {
        if isFocused { return palette.onAccent }
        return isSelected ? palette.onAccent : .white.opacity(0.75)
    }

    private func background(_ isFocused: Bool) -> AnyShapeStyle {
        if isFocused { return AnyShapeStyle(Color.white) }
        return isSelected
            ? AnyShapeStyle(palette.accent)
            : AnyShapeStyle(Color.white.opacity(0.08))
    }
}

// MARK: - Hero

/// A rotating showcase of a handful of titles, each with its backdrop, title
/// treatment and a one-line pitch — the opening shot of every streaming app.
struct HeroCarousel: View {
    let items: [HeroItem]
    let metrics: LayoutMetrics
    let onSelect: (HeroItem) -> Void

    /// The hero's own controls, so the carousel can tell when the viewer is
    /// acting on the current title.
    private enum Control: Hashable { case details, next }

    @Environment(\.palette) private var palette
    @State private var index = 0
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
        }
        .frame(height: metrics.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: items.count) { await autoAdvance() }
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

    /// Two gradients: one down the frame so the bottom melts into the app
    /// background, one across it so the copy on the left stays readable.
    private var scrims: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.1), location: 0.28),
                    .init(color: .black.opacity(0.45), location: 0.62),
                    .init(color: palette.background.opacity(0.94), location: 0.9),
                    .init(color: palette.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: palette.background.opacity(0.92), location: 0),
                    .init(color: palette.background.opacity(0.55), location: 0.38),
                    .init(color: .clear, location: 0.78),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: metrics.lerp(12, 22)) {
            HeroTitleTreatment(hero: current, metrics: metrics)

            HeroFacts(item: current.item, metrics: metrics)

            if let synopsis = current.item.description?.trimmed, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: metrics.lerp(14, 24), weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(Int(metrics.lerp(2, 3).rounded()))
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .overArtwork()
            }

            HStack(spacing: metrics.lerp(12, 20)) {
                Button {
                    onSelect(current)
                } label: {
                    Text("View details")
                }
                .buttonStyle(
                    NuvioButtonStyle(kind: .prominent, icon: "info.circle.fill", compact: metrics.isCompact)
                )
                .focused($focusedControl, equals: .details)

                if items.count > 1 {
                    Button {
                        advance()
                    } label: {
                        Text("Next")
                    }
                    .buttonStyle(
                        NuvioButtonStyle(kind: .glass, icon: "forward.fill", compact: metrics.isCompact)
                    )
                    .focused($focusedControl, equals: .next)
                }
            }
            .padding(.top, metrics.lerp(2, 6))

            if items.count > 1 {
                PageDots(count: items.count, index: index)
                    .padding(.top, metrics.lerp(4, 10))
            }
        }
        .frame(width: metrics.heroContentWidth, alignment: .leading)
        .padding(.horizontal, metrics.pagePadding)
        .padding(.bottom, metrics.lerp(26, 64))
        .animation(.easeInOut(duration: 0.45), value: index)
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
            .tracking(-1.2)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The facts line under a hero title: type, year, rating, a genre or two.
private struct HeroFacts: View {
    let item: MetaItem
    let metrics: LayoutMetrics

    var body: some View {
        HStack(spacing: metrics.lerp(8, 12)) {
            MetaChip(text: HomeViewModel.typeLabel(item.type), emphasised: true)

            if let year = item.releaseInfo?.trimmed, !year.isEmpty {
                MetaChip(text: year)
            }
            if let rating = item.imdbRating?.trimmed, !rating.isEmpty {
                RatingChip(rating: rating)
            }
            ForEach(item.genres.prefix(Int(metrics.lerp(1, 2).rounded())), id: \.self) { genre in
                MetaChip(text: genre)
            }
        }
        .scaleEffect(metrics.lerp(0.78, 1), anchor: .leading)
        .frame(height: metrics.lerp(26, 36), alignment: .leading)
    }
}

/// Carousel position, drawn as the widening pill every streaming app uses.
private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { position in
                Capsule()
                    .fill(.white.opacity(position == index ? 0.95 : 0.32))
                    .frame(width: position == index ? 34 : 9, height: 9)
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


// MARK: - Shelves

struct CatalogRowView: View {
    let row: CatalogRow
    let metrics: LayoutMetrics
    let onSelect: (MetaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.lerp(8, 12)) {
            header
                // Titles line up with the page; the posters scroll past the edge.
                .padding(.horizontal, metrics.pagePadding)

            switch row.content {
            case .loading:
                placeholders
            case .failed:
                Text("This catalog didn't respond.")
                    .font(.system(size: metrics.lerp(13, 20)))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, metrics.pagePadding)
                    .padding(.vertical, 20)
            case .loaded(let items):
                posters(items)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(row.title)
                .font(.system(size: metrics.rowTitleSize, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(.white)

            Text(row.addonName.uppercased())
                .font(.system(size: metrics.lerp(10, 14), weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, metrics.lerp(7, 10))
                .padding(.vertical, metrics.lerp(3, 4))
                .background(
                    Capsule().stroke(.white.opacity(0.16), lineWidth: 1)
                )

            Spacer(minLength: 0)
        }
    }

    private var placeholders: some View {
        HStack(spacing: metrics.posterSpacing) {
            ForEach(0..<6, id: \.self) { _ in
                SkeletonBlock(cornerRadius: metrics.posterCornerRadius)
                    .frame(width: metrics.posterWidth, height: metrics.posterHeight)
            }
        }
        .padding(.horizontal, metrics.pagePadding)
        .padding(.vertical, metrics.lerp(6, 16))
    }

    private func posters(_ items: [MetaItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: metrics.posterSpacing) {
                ForEach(items) { item in
                    PosterCard(
                        item: item,
                        addonBaseURL: row.addonBaseURL,
                        metrics: metrics
                    ) { onSelect(item) }
                }
            }
            .padding(.horizontal, metrics.pagePadding)
            // Room for the focus effect to grow into without clipping.
            .padding(.vertical, metrics.posterFocusPadding)
        }
        // The grown card and its glow reach outside the scroll view's bounds.
        .scrollClipDisabled()
    }
}

// MARK: - Poster

struct PosterCard: View {
    let item: MetaItem
    let addonBaseURL: String
    let metrics: LayoutMetrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RemoteImage(
                url: AddonClient.resolve(item.poster, relativeTo: addonBaseURL)
            ) {
                AnyView(fallback)
            }
        }
        .buttonStyle(PosterCardStyle(item: item, metrics: metrics))
        .accessibilityLabel(item.name)
    }

    /// Addons don't always have artwork; the title still has to be readable.
    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [.white.opacity(0.14), .white.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 10) {
                Image(systemName: item.type.lowercased() == "series" ? "tv" : "film")
                    .font(.system(size: metrics.lerp(20, 34), weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text(item.name)
                    .font(.system(size: metrics.lerp(11, 17), weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
            }
            .padding(10)
        }
    }
}

/// The whole look of a poster: the crop, the focus lift and glow, the rating
/// badge that fades in, and the caption that only appears for the focused card
/// so the shelf stays clean.
private struct PosterCardStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    let item: MetaItem
    let metrics: LayoutMetrics

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            VStack(alignment: .leading, spacing: metrics.lerp(6, 10)) {
                artwork(configuration, isFocused: isFocused)
                caption(isFocused: isFocused)
            }
            .scaleEffect(
                configuration.isPressed ? 0.97 : (isFocused ? metrics.posterFocusScale : 1),
                anchor: .center
            )
            .zIndex(isFocused ? 1 : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.74), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    private func artwork(_ configuration: Configuration, isFocused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.posterCornerRadius, style: .continuous)

        return configuration.label
            .frame(width: metrics.posterWidth, height: metrics.posterHeight)
            .clipShape(shape)
            .overlay {
                // A rating corner that only shows on the focused card, so the
                // shelf reads as artwork until you land on something.
                if let rating = item.imdbRating?.trimmed, !rating.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                Text(rating)
                            }
                            .font(.system(size: metrics.lerp(10, 15), weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.62), in: Capsule())
                        }
                    }
                    .padding(metrics.lerp(6, 10))
                    .opacity(isFocused ? 1 : 0)
                }
            }
            .overlay {
                shape.strokeBorder(
                    isFocused ? Color.white.opacity(0.95) : Color.white.opacity(0.10),
                    lineWidth: isFocused ? (metrics.lerp(2, 4)) : 1
                )
            }
            .shadow(
                color: isFocused ? palette.accent.opacity(0.5) : .black.opacity(0.5),
                radius: isFocused ? (metrics.lerp(14, 34)) : 10,
                y: isFocused ? (metrics.lerp(8, 20)) : 6
            )
    }

    /// Reserved space, so the shelf doesn't jump when the caption appears.
    private func caption(isFocused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.system(size: metrics.lerp(12, 19), weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let year = item.releaseInfo?.trimmed, !year.isEmpty {
                Text(year)
                    .font(.system(size: metrics.lerp(10, 15), weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(width: metrics.posterWidth, alignment: .leading)
        .frame(height: metrics.lerp(30, 48), alignment: .top)
        .opacity(isFocused ? 1 : 0)
    }
}

/// Holds a shelf's space while its first page is loading.
private struct ShelfSkeleton: View {
    let metrics: LayoutMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.lerp(8, 14)) {
            SkeletonBlock(cornerRadius: 8)
                .frame(width: metrics.lerp(140, 300), height: metrics.lerp(18, 30))
                .padding(.horizontal, metrics.pagePadding)

            HStack(spacing: metrics.posterSpacing) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonBlock(cornerRadius: metrics.posterCornerRadius)
                        .frame(width: metrics.posterWidth, height: metrics.posterHeight)
                }
            }
            .padding(.horizontal, metrics.pagePadding)
        }
    }
}

/// Shown when nothing could be loaded at all.
private struct EmptyStateCard: View {
    let message: String
    let metrics: LayoutMetrics
    let onRetry: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.lerp(14, 24)) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: metrics.lerp(30, 54), weight: .light))
                .foregroundStyle(palette.accent)

            Text("Nothing to show yet")
                .font(.system(size: metrics.lerp(22, 40), weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: metrics.lerp(14, 22)))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            Button("Try again", action: onRetry)
                .buttonStyle(NuvioButtonStyle(kind: .prominent, icon: "arrow.clockwise", compact: metrics.isCompact))
        }
        .padding(metrics.lerp(24, 44))
        .frame(maxWidth: metrics.isCompact ? .infinity : 900, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
    }
}
#endif
