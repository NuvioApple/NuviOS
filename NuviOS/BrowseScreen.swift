#if os(iOS)
import SwiftUI
import Combine

/// One tab's worth of catalogs.
///
/// Home opens on a full-bleed billboard — the shape Netflix, Disney+ and the
/// Apple TV app all open with — and everything below it is rows of artwork.
/// The Movies and Series tabs are the same data narrowed to one content type,
/// with a genre bar instead of a billboard.
struct BrowseScreen: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var model: HomeViewModel

    /// `nil` on Home; a Stremio content type on the other tabs.
    let filter: String?
    let title: String
    let showsHero: Bool

    @Environment(\.palette) private var palette

    @State private var selected: MetaSelection?
    @State private var openFolder: OpenFolder?
    @State private var scrollProgress: Double = 0
    @State private var genre: String?

    private var hasBillboard: Bool { showsHero && !model.heroItems.isEmpty }

    private var rows: [CatalogRow] {
        model.rows(matching: filter).map { row in
            guard let genre else { return row }
            var narrowed = row
            narrowed.content = .loaded(row.items.filter { item in
                item.genres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
            })
            return narrowed
        }
        .filter { !$0.isEmptyAfterLoading }
    }

    /// The genres actually present in this tab's titles, most common first, so
    /// the bar never offers a filter that empties the screen.
    private var genres: [String] {
        var counts: [String: Int] = [:]
        for row in model.rows(matching: filter) {
            for item in row.items {
                for genre in item.genres where !genre.trimmed.isEmpty {
                    counts[genre.trimmed, default: 0] += 1
                }
            }
        }
        return counts
            .filter { $0.value >= 3 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(14)
            .map(\.key)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // Flat, not the ambient glow: the billboard fades into the
                // page, and a tinted backdrop leaves a seam where it ends.
                palette.background.ignoresSafeArea()

                // Collections alone are enough to fill Home, even when the
                // addons' own catalogs came back empty.
                if rows.isEmpty, !(showsHero && !model.collections.isEmpty) {
                    placeholderOrEmpty
                } else {
                    content
                }

                topBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selected) { selection in
                DetailView(selection: selection)
            }
            .navigationDestination(item: $openFolder) { open in
                FolderScreen(open: open, addons: model.addons)
            }
        }
    }

    // MARK: Chrome

    /// Home carries no chrome at all: Nuvio doesn't put its name over the
    /// artwork, and the profile lives in the tab bar's trailing corner rather
    /// than up here. Movies and Series keep a plain title because they open on
    /// a row rather than on a billboard.
    @ViewBuilder
    private var topBar: some View {
        if !showsHero {
            FloatingTopBar(progress: 1) {
                AnyView(
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                )
            } trailing: {
                EmptyView()
            }
        }
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Phone.shelfSpacing) {
                if hasBillboard {
                    Billboard(items: model.heroItems, isOnScreen: scrollProgress < 0.4) { hero in
                        selected = MetaSelection(item: hero.item, addonBaseURL: hero.addonBaseURL)
                    }
                    .padding(.bottom, 2)
                } else {
                    // Clears the floating bar, which is opaque on these tabs.
                    Color.clear.frame(height: 40)
                }

                if !showsHero, !genres.isEmpty {
                    GenreBar(genres: genres, selection: $genre)
                }

                if showsHero, !library.titles.isEmpty {
                    myList
                }

                // The user's own shelves sit above the addons' catalogs, the
                // way pinned collections do upstream.
                if showsHero {
                    ForEach(model.collections) { collection in
                        CollectionShelf(collection: collection) { folder in
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

                ForEach(rows) { row in
                    catalogShelf(row)
                }
            }
            .padding(.bottom, Phone.tabBarClearance)
        }
        // Only the billboard is allowed under the status bar; without one, the
        // first row would slide beneath the top bar.
        .ignoresSafeArea(edges: hasBillboard ? .top : [])
        .scrollIndicators(.hidden)
        .trackingScrollProgress(over: 220, into: $scrollProgress)
        .refreshable { await model.refresh(session: session, profile: profiles.current) }
    }

    private var myList: some View {
        Shelf(
            title: "My List",
            items: library.titles
        ) { saved, _ in
            PosterCard(item: saved.item, addonBaseURL: saved.addonBaseURL) {
                selected = MetaSelection(item: saved.item, addonBaseURL: saved.addonBaseURL)
            }
            .contextMenu {
                Button("Remove from My List", systemImage: "minus.circle", role: .destructive) {
                    library.remove(saved)
                }
            }
        }
    }

    @ViewBuilder
    private func catalogShelf(_ row: CatalogRow) -> some View {
        switch row.content {
        case .loading:
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: row.title, subtitle: row.addonName)
                HStack(spacing: Phone.posterSpacing) {
                    ForEach(0..<5, id: \.self) { _ in PosterPlaceholder() }
                }
                .padding(.horizontal, Phone.pagePadding)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                ShelfHeader(title: row.title, subtitle: row.addonName)
                Text("This catalog didn't respond.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, Phone.pagePadding)
            }
        case .loaded(let items):
            let ranked = Self.isRanked(row.title)
            Shelf(
                title: row.title,
                subtitle: row.addonName,
                isRanked: ranked,
                items: ranked ? Array(items.prefix(10)) : items
            ) { item, index in
                PosterCard(
                    item: item,
                    addonBaseURL: row.addonBaseURL,
                    rank: ranked ? index + 1 : nil
                ) {
                    selected = MetaSelection(
                        item: item,
                        addonBaseURL: row.addonBaseURL,
                        related: items
                    )
                }
                .contextMenu {
                    Button(
                        library.contains(item) ? "Remove from My List" : "Add to My List",
                        systemImage: library.contains(item) ? "minus.circle" : "plus.circle"
                    ) {
                        library.toggle(item, addonBaseURL: row.addonBaseURL)
                    }
                }
            }
        }
    }

    /// Which rows get the oversized numerals. A ranked row is one whose name
    /// already claims an order — anything else numbered would be a lie.
    private static func isRanked(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return ["top 10", "top ten", "trending", "most watched"].contains { lowered.contains($0) }
    }

    @ViewBuilder
    private var placeholderOrEmpty: some View {
        if model.isLoading {
            ScrollView {
                VStack(alignment: .leading, spacing: Phone.shelfSpacing) {
                    Color.clear.frame(height: 44)

                    ForEach(0..<3, id: \.self) { _ in ShelfPlaceholder() }
                }
            }
            .allowsHitTesting(false)
        } else {
            EmptyState(
                message: model.loadError
                    ?? (genre.map { "Nothing in your catalogs is tagged \($0)." }
                        ?? "Nothing here yet. Your addons publish no \(title.lowercased()) catalogs.")
            ) {
                Task { await model.refresh(session: session, profile: profiles.current) }
            }
            .padding(.horizontal, Phone.pagePadding)
            .padding(.top, 90)
        }
    }
}

// MARK: - Billboard

/// The full-bleed feature at the top of Home: artwork to the screen edges,
/// the title's own logo, and the two controls every streaming app puts there.
/// It advances on its own so the screen has a pulse, and stops the moment a
/// finger touches it.
private struct Billboard: View {
    let items: [HeroItem]
    /// False once the page has been scrolled past the billboard — a trailer
    /// playing under the rows is just wasted battery.
    let isOnScreen: Bool
    let onSelect: (HeroItem) -> Void

    @State private var index = 0
    @State private var isInteracting = false
    /// Which page, if any, currently has a trailer on screen. The carousel
    /// holds while one plays, the way upstream waits for `onTrailerEnded`.
    @State private var trailerIndex: Int?

    private let advance = Timer.publish(every: 7, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, hero in
                BillboardPage(
                    hero: hero,
                    isCurrent: offset == index && isOnScreen,
                    onTrailerChange: { isPlaying in
                        trailerIndex = isPlaying ? offset : (trailerIndex == offset ? nil : trailerIndex)
                    }
                ) { onSelect(hero) }
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Sized against the window, not just its width. A pure aspect ratio
        // fills the top of an iPhone nicely and then runs several screenfuls
        // deep in a wide, short Mac window; `billboardHeight` takes the
        // window's height into account as well.
        .frame(height: Phone.billboardHeight)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                PageIndicator(count: items.count, index: index)
                    .padding(.bottom, 10)
            }
        }
        // A stretchy header: pulling down grows the artwork rather than
        // exposing the background behind it.
        .visualEffect { view, geometry in
            let minY = geometry.frame(in: .scrollView).minY
            let height = max(geometry.size.height, 1)
            return view
                .scaleEffect(minY > 0 ? 1 + minY / height : 1, anchor: .bottom)
                .offset(y: minY > 0 ? -minY / 2 : 0)
        }
        .onReceive(advance) { _ in
            guard items.count > 1, !isInteracting, trailerIndex == nil else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                index = (index + 1) % items.count
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4).onChanged { _ in isInteracting = true }
        )
    }
}

private struct BillboardPage: View {
    let hero: HeroItem
    /// The visible page. Only this one is allowed to fetch or play anything.
    let isCurrent: Bool
    let onTrailerChange: (Bool) -> Void
    let onTap: () -> Void

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tmdb: TmdbSettings
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase

    @State private var youTubeKey: String?
    @State private var isTrailerVisible = false
    @State private var isMuted = true

    private var backdropURL: URL? {
        AddonClient.resolve(hero.item.background ?? hero.item.poster, relativeTo: hero.addonBaseURL)
    }

    private var logoURL: URL? {
        guard let logo = hero.item.logo?.trimmed, !logo.isEmpty else { return nil }
        return AddonClient.resolve(logo, relativeTo: hero.addonBaseURL)
    }

    private var isSaved: Bool { library.contains(hero.item) }

    var body: some View {
        // The copy drives the layout and the artwork goes behind it: a `.fill`
        // image reports an enormous ideal size, so as a ZStack sibling it
        // would stretch the page instead of being cropped by it.
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            titleTreatment

            if !tagline.isEmpty, !isTrailerVisible {
                Text(tagline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
            }

            controls
                .padding(.top, 4)
                .padding(.bottom, Phone.billboardBottomInset)
        }
        .frame(maxWidth: Phone.billboardContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background { backdrop }
        .overlay(alignment: .topTrailing) { muteButton }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: trailerTaskID) { await manageTrailer() }
        .onDisappear { stopTrailer() }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            RemoteImage(url: backdropURL)
                .opacity(isTrailerVisible ? 0 : 1)

            if let youTubeKey {
                YouTubeTrailerView(
                    videoID: youTubeKey,
                    isMuted: isMuted,
                    onReady: {
                        withAnimation(.easeInOut(duration: 0.8)) { isTrailerVisible = true }
                        onTrailerChange(true)
                    },
                    onEnded: { stopTrailer() }
                )
                .opacity(isTrailerVisible ? 1 : 0)
                // The embed is 16:9 and the billboard is taller, so the
                // player is blown up and centre-cropped the way a backdrop
                // would be rather than squashed to fit.
                .aspectRatio(16 / 9, contentMode: .fill)
                .allowsHitTesting(false)
            }

            // Two stops: one that keeps the type legible, one that melts the
            // artwork into the page rather than ending on a hard edge.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.15), location: 0.42),
                    .init(color: .black.opacity(0.72), location: 0.72),
                    .init(color: palette.background.opacity(0.96), location: 0.93),
                    .init(color: palette.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var muteButton: some View {
        if isTrailerVisible {
            Button {
                isMuted.toggle()
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(.pressable)
            .padding(.top, 58)
            .padding(.trailing, Phone.pagePadding)
            .transition(.opacity)
            .accessibilityLabel(isMuted ? "Unmute trailer" : "Mute trailer")
        }
    }

    // MARK: Trailer

    /// Re-runs whenever anything that should start or stop a trailer changes.
    private var trailerTaskID: String {
        "\(isCurrent)|\(scenePhase == .active)|\(tmdb.canFetchTrailers)|\(tmdb.apiKey.trimmed.isEmpty)"
    }

    private func manageTrailer() async {
        guard isCurrent, scenePhase == .active, tmdb.canFetchTrailers else {
            stopTrailer()
            return
        }

        // The lookup goes first and the beat of stillness runs alongside it,
        // not after it. Two TMDB round trips took longer than the carousel's
        // dwell, so the task was cancelled by the page turning before it ever
        // produced a key — the same race on every page, so no trailer ever
        // played. Overlapping them spends the pause we wanted anyway.
        async let resolved = TrailerService.shared.youTubeKey(
            for: hero.item,
            apiKey: tmdb.apiKey
        )
        async let beat: Void = Task.sleep(for: .seconds(2.5))

        let key = await resolved
        try? await beat
        guard !Task.isCancelled, isCurrent, let key else { return }

        isMuted = true
        youTubeKey = key
        // Claims the carousel now rather than once the embed reports playing:
        // loading the iframe API is itself a network round trip, and a page
        // turn in the middle of it throws the trailer away.
        onTrailerChange(true)

        // ...and releases it if the embed never actually starts. A video that
        // is age-gated, region-blocked or has embedding disabled would
        // otherwise hold the carousel on one page for good.
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled, !isTrailerVisible else { return }
        stopTrailer()
    }

    private func stopTrailer() {
        guard youTubeKey != nil || isTrailerVisible else { return }
        withAnimation(.easeInOut(duration: 0.4)) { isTrailerVisible = false }
        youTubeKey = nil
        isMuted = true
        onTrailerChange(false)
    }

    // MARK: Copy

    private var shareText: String {
        hero.item.id.hasPrefix("tt")
            ? "\(hero.item.name) — https://www.imdb.com/title/\(hero.item.id)/"
            : hero.item.name
    }

    private var tagline: String {
        var parts: [String] = []
        if let year = hero.item.releaseInfo?.trimmed, !year.isEmpty { parts.append(year) }
        parts.append(HomeViewModel.typeLabel(hero.item.type))
        parts.append(contentsOf: hero.item.genres.prefix(2))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var titleTreatment: some View {
        if let logoURL {
            AsyncImage(url: logoURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    typeset
                }
            }
            .frame(maxWidth: Phone.billboardLogoWidth, maxHeight: Phone.billboardLogoHeight)
            .background {
                // Addons ship dark logos as often as white ones, and a dark one
                // on a darkened backdrop is unreadable. A soft lift behind it
                // rescues those without touching how a white logo looks.
                RadialGradient(
                    colors: [.white.opacity(0.16), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 150
                )
                .blendMode(.plusLighter)
            }
        } else {
            typeset
        }
    }

    private var typeset: some View {
        Text(hero.item.name)
            .font(.system(size: Phone.billboardTitleSize, weight: .heavy, design: .rounded))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 24)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
    }

    /// My List · Details · Share — the streaming apps' trio, minus Play, which
    /// this build can't honour yet.
    private var controls: some View {
        HStack(spacing: 22) {
            BillboardAction(
                title: "My List",
                systemImage: isSaved ? "checkmark" : "plus"
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    library.toggle(hero.item, addonBaseURL: hero.addonBaseURL)
                }
            }

            Button(action: onTap) {
                Label("Details", systemImage: "info.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(palette.accent)
            .foregroundStyle(palette.onAccent)

            ShareLink(item: shareText) {
                VStack(spacing: 3) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(height: 22)
                    Text("Share")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 62)
            }
            .buttonStyle(.pressable)
        }
    }
}

/// A stacked icon-over-label control, the way the streaming apps flank their
/// primary button.
private struct BillboardAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 62)
        }
        .buttonStyle(.pressable)
    }
}

private struct PageIndicator: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { position in
                Capsule()
                    .fill(.white.opacity(position == index ? 0.9 : 0.28))
                    .frame(width: position == index ? 16 : 5, height: 5)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
    }
}

// MARK: - Genre bar

/// The chip row Netflix puts at the top of its Movies and TV tabs. Tapping the
/// active chip clears the filter.
private struct GenreBar: View {
    let genres: [String]
    @Binding var selection: String?

    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.self) { genre in
                    let isOn = selection == genre
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = isOn ? nil : genre
                        }
                    } label: {
                        Text(genre)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? palette.onAccent : .white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassPill(tint: isOn ? palette.accent : nil)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, Phone.pagePadding)
        }
    }
}

// MARK: - Profile switcher

/// The short sheet behind the avatar in the top bar. The full "who's
/// watching" screen belongs to launch; this is the one-tap version.
struct ProfileSwitcherSheet: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Who's watching?")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            profiles.select(profile)
                            library.activate(profile: profile)
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                ProfileAvatar(
                                    profile: profile,
                                    size: 66,
                                    isActive: profile.index == profiles.currentIndex
                                )
                                Text(profile.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(
                                        .white.opacity(profile.index == profiles.currentIndex ? 0.95 : 0.55)
                                    )
                                    .lineLimit(1)
                            }
                            .frame(width: 82)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
