import SwiftUI

// The user's collections, on both shells. A collection is a shelf of folders;
// opening a folder shows the catalogs it bundles, tabbed.

// MARK: - Shared pieces

/// What a folder tile looks like at a given shape. Android stores the shape
/// per folder — square covers with an emoji, wide art, or a plain poster.
enum FolderTile {
    static func size(_ shape: PosterShape, height: CGFloat) -> CGSize {
        CGSize(width: (height * shape.aspectRatio).rounded(), height: height.rounded())
    }
}

/// A folder opened from a shelf. Carried through navigation, so it holds only
/// what the destination needs to load itself.
struct OpenFolder: Identifiable, Hashable {
    let collectionID: String
    let collectionTitle: String
    let folder: CollectionFolder
    let showAllTab: Bool
    let backdropURL: String?

    var id: String { "\(collectionID)|\(folder.id)" }

    static func == (lhs: OpenFolder, rhs: OpenFolder) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The artwork on a folder tile: the author's cover, their emoji over a tint,
/// or the folder's initial when they set neither.
struct FolderCover: View {
    let folder: CollectionFolder
    let size: CGSize
    let cornerRadius: CGFloat
    /// Whether the animated cover should be running: focus on the TV, simply
    /// being on screen on the phone.
    var isAnimating: Bool = true

    @Environment(\.palette) private var palette
    @State private var animationReady = false

    var body: some View {
        ZStack {
            if let cover = folder.coverImageURL, let url = URL(string: cover) {
                RemoteImage(url: url) { AnyView(tint) }
            } else {
                tint
            }

            if let emoji = folder.coverEmoji {
                Text(emoji)
                    .font(.system(size: size.height * 0.42))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            } else if folder.coverImageURL == nil {
                Text(String(folder.title.prefix(1)).uppercased())
                    .font(.system(size: size.height * 0.34, weight: .black))
                    .foregroundStyle(.white.opacity(0.85))
            }

            // The author's animation, over the static cover and only once it
            // has frames — otherwise the tile would blink to empty first.
            if let animation = folder.animatedCoverURL {
                AnimatedImage(
                    url: animation,
                    maxPixelSize: max(size.width, size.height),
                    isPlaying: isAnimating,
                    onReady: { ready in
                        withAnimation(.easeOut(duration: 0.2)) { animationReady = ready }
                    }
                )
                .frame(width: size.width, height: size.height)
                .clipped()
                .opacity(isAnimating && animationReady ? 1 : 0)
            }

            // Keeps a title legible over whatever artwork the author chose.
            if !folder.hideTitle, folder.coverImageURL != nil {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var tint: some View {
        LinearGradient(
            colors: [palette.accent.opacity(0.55), palette.accent.opacity(0.16)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// The artwork behind a folder's banner: the author's backdrop, drifting
/// slowly, under the layered scrims a title card is built from.
///
/// Three things separate this from a cropped photo. The drift keeps a still
/// frame alive without asking anyone to watch it. The scrims are stacked
/// rather than single — one down the frame so the artwork dissolves into the
/// page instead of ending on a seam, one across it so type stays legible over
/// whatever was in the shot. The vignette pulls the eye off the edges and into
/// the middle, which is what a lens does and a crop doesn't.
struct CinematicBackdrop: View {
    let url: URL?
    /// Used only when the author gave the folder no still backdrop: their
    /// animated cover is better than an empty frame.
    var animated: URL? = nil
    let height: CGFloat
    /// Off when the banner isn't on screen, so neither the drift nor the
    /// animation runs against a view nobody is looking at.
    var isActive: Bool = true
    /// The folder's own hero video. It plays once over the still artwork and
    /// then fades back to it, rather than looping behind the title.
    var videoURL: URL? = nil
    /// The hero video is over, as it fades back to the still.
    var onVideoFinish: () -> Void = {}

    @Environment(\.palette) private var palette
    @State private var drifted = false

    var body: some View {
        ZStack {
            artwork
                // A slow push in. Small on purpose: enough that the frame
                // isn't dead, not so much that it reads as a zoom.
                .scaleEffect(drifted ? 1.10 : 1.02)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipped()

            if let videoURL {
                HeroVideo(url: videoURL, isActive: isActive, onFinish: onVideoFinish)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }

            // Down the frame: the artwork melts into the page.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .black.opacity(0.05), location: 0.32),
                    .init(color: palette.background.opacity(0.55), location: 0.7),
                    .init(color: palette.background.opacity(0.95), location: 0.9),
                    .init(color: palette.background, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Across it: the type on the leading edge stays readable whatever
            // the artwork is doing behind it.
            LinearGradient(
                stops: [
                    .init(color: palette.background.opacity(0.85), location: 0),
                    .init(color: palette.background.opacity(0.35), location: 0.42),
                    .init(color: .clear, location: 0.8)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            RadialGradient(
                colors: [.clear, .black.opacity(0.38)],
                center: .center,
                startRadius: height * 0.28,
                endRadius: height * 1.05
            )
            .blendMode(.multiply)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: isActive) {
            guard isActive, !drifted else { return }
            withAnimation(.easeInOut(duration: 18)) { drifted = true }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url {
            RemoteImage(url: url) { AnyView(wash) }
        } else if let animated {
            AnimatedImage(url: animated, maxPixelSize: height * 1.8, isPlaying: isActive)
        } else {
            wash
        }
    }

    /// Never a bare black rectangle: a folder with no artwork still gets a
    /// frame with some depth to it.
    private var wash: some View {
        LinearGradient(
            colors: [palette.accent.opacity(0.42), palette.background],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - iOS

#if os(iOS) || os(macOS) || os(tvOS)

/// One collection as a shelf of folder tiles.
///
/// A phone has no focus engine, so the shelf decides which single tile is
/// being *looked at* and animates only that one. A pointer, where there is
/// one, is the closest thing to the TV's focus; without one it's whichever
/// tile the scroll settled on, centred in the viewport.
struct CollectionShelf: View {
    let collection: MediaCollection
    let onOpen: (CollectionFolder) -> Void

    /// The tile under the pointer, on the platforms that have one.
    @State private var hovered: String?
    /// The tile nearest the middle of the shelf, tracked by the scroll view.
    @State private var centered: String?
    /// Motion during a scroll is not something anyone can follow, so the
    /// animation waits for the scroll to come to rest.
    @State private var isSettled = true
    /// The tile that has focus, so it can be drawn above the ones beside it.
    @State private var focusedFolderID: String?
    @Environment(\.shelfBand) private var shelfBand
    @Environment(\.shelfID) private var shelfID
    #if os(tvOS)
    @Environment(HeroFocus.self) private var heroFocus: HeroFocus?
    #endif

    /// One tile at a time, the way one tile at a time holds focus on the TV.
    private var animating: String? {
        if let hovered { return hovered }
        guard isSettled else { return nil }
        // Until the shelf has been scrolled at all, the eye starts at its
        // leading edge, so that tile stands in for the centred one.
        return centered ?? folders.first?.id
    }

    private var tileHeight: CGFloat { Phone.posterHeight * 0.82 }

    private var folders: [CollectionFolder] { collection.visibleFolders }

    var body: some View {
        ShelfRow(
            id: "collection|\(collection.id)",
            header: ShelfHeader(title: collection.title, subtitle: collection.pinToTop ? "Pinned" : nil)
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Phone.posterSpacing) {
                    ForEach(folders) { folder in
                        Button { onOpen(folder) } label: {
                            FocusReader { isFocused in
                                tile(folder)
                                    #if os(tvOS)
                                    // The hero shows this collection's
                                    // header while its tile has focus.
                                    .onChange(of: isFocused) { _, focused in
                                        if focused {
                                            focusedFolderID = folder.id
                                            heroFocus?.focus(
                                                collection: CollectionHero(folder: folder, collection: collection),
                                                // This view builds the row itself, so the
                                                // id isn't in its environment yet.
                                                row: "collection|\(collection.id)"
                                            )
                                        }
                                    }
                                    #endif
                            }
                            .padding(.top, Phone.focusSlack + shelfBand)
                            .padding(.bottom, Phone.focusSlack)
                        }
                        #if os(tvOS)
                        // Wide tiles, so a small lift: the default grows them
                        // into the title above and the tiles beside them.
                        .buttonStyle(PressableStyle(scale: 0.97, focusScale: 1.04))
                        #else
                        .buttonStyle(.pressable)
                        #endif
                        .accessibilityLabel("\(folder.title), \(collection.title)")
                        // A button's own z-index only orders it against its
                        // own contents; the row needs it on the tile itself,
                        // or a later neighbour paints over the focused one.
                        .zIndex(focusedFolderID == folder.id ? 1 : 0)
                        .platformOnHover { inside in
                            // Leaving a tile only clears the pointer if it
                            // hasn't already landed on its neighbour.
                            if inside { hovered = folder.id }
                            else if hovered == folder.id { hovered = nil }
                        }
                    }
                }
                .padding(.horizontal, Phone.pagePadding)
                .padding(.top, Phone.shelfHeaderBand)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            .scrollPosition(id: $centered, anchor: .center)
            .onScrollPhaseChange { _, phase in
                isSettled = phase == .idle
            }
        }
    }

    /// Whether a tile's animated cover should be running. The television has a
    /// real answer — the remote is pointing at it — so nothing else counts
    /// there; elsewhere the shelf's pointer-or-centre heuristic stands in.
    private func shouldAnimate(_ folder: CollectionFolder, isFocused: Bool) -> Bool {
        #if os(tvOS)
        isFocused
        #else
        animating == folder.id
        #endif
    }

    private func tile(_ folder: CollectionFolder) -> some View {
        let size = FolderTile.size(folder.tileShape, height: tileHeight)
        return VStack(alignment: .leading, spacing: 8) {
            // On the TV the tile that is *being looked at* is simply the one
            // that holds focus, so it answers for itself rather than being
            // told by the shelf — and its animated cover runs only then.
            // The shelf's own guess at what is being looked at is a stand-in
            // for focus on the platforms that have no focus engine; using it
            // here as well would leave a tile animating that the remote isn't
            // pointing at.
            FocusReader { isFocused in
                FolderCover(
                    folder: folder,
                    size: size,
                    cornerRadius: Phone.posterRadius,
                    isAnimating: shouldAnimate(folder, isFocused: isFocused)
                )
                #if !os(tvOS)
                // On the TV the button style already lifts the whole tile;
                // a second lift here took it past the gap to its neighbours.
                .scaleEffect(isFocused ? 1.06 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 22, y: 12)
                .animation(.spring(response: 0.34, dampingFraction: 0.74), value: isFocused)
                #endif
            }

            if !folder.hideTitle {
                Text(folder.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(width: size.width, alignment: .leading)
            }
        }
    }
}

/// A folder's own filter. Folders gather catalogs of both kinds, so the
/// screen carries the movies/shows split the shell's tabs give everywhere
/// else in the app.
enum FolderTypeFilter: String, CaseIterable, Identifiable {
    case all, movies, shows

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .shows: "Shows"
        }
    }

    /// Stremio's types. Anything that is neither — a channel, a live stream —
    /// shows under "All" alone.
    func matches(_ type: String) -> Bool {
        switch self {
        case .all: true
        case .movies: type.caseInsensitiveCompare("movie") == .orderedSame
        case .shows: type.caseInsensitiveCompare("series") == .orderedSame
        }
    }
}

/// An opened folder: its catalogs as tabs over a grid of artwork.
struct FolderScreen: View {
    let open: OpenFolder
    let addons: AddonIndex

    @StateObject private var model = CollectionFolderModel()
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var selected: MetaSelection?
    /// The folder's hero video has finished (or never played), so its title
    /// can show. Folders without a hero video never wait.
    @State private var heroVideoDone = false
    #if os(tvOS)
    @EnvironmentObject private var tmdb: TmdbSettings
    #endif
    /// Folders only: the shell's own tabs do this everywhere else.
    @State private var typeFilter: FolderTypeFilter = .all
    #if os(macOS)
    /// Which card in the single-catalog grid is open, so its row makes room.
    @State private var gridExpansion = ShelfExpansion()
    /// The grid's own width, which decides how many columns fit.
    @State private var gridWidth: CGFloat = 0
    #endif

    private var titleHeldBack: Bool {
        heroVideoURL != nil && !heroVideoDone
    }

    private var heroVideoURL: URL? {
        open.folder.heroVideoURL.flatMap(URL.init(string:))
    }

    var body: some View {
        ZStack(alignment: .top) {
            palette.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    banner

                    // Nothing under the banner shows until the hero video is
                    // over: the video plays alone, like a cold open, and the
                    // page comes in after it. Disabled meanwhile so the TV's
                    // focus can't land on a row nobody can see.
                    VStack(alignment: .leading, spacing: 18) {
                        if !model.tabs.isEmpty {
                            filterBar
                        }

                        if !model.skippedProviders.isEmpty {
                            note(
                                "\(model.skippedProviders.joined(separator: " and ")) sources in this folder need credentials this device doesn't have."
                            )
                        }

                        rows
                    }
                    .opacity(titleHeldBack ? 0 : 1)
                    .offset(y: titleHeldBack ? 24 : 0)
                    .disabled(titleHeldBack)
                    .animation(.easeOut(duration: 1.0).delay(0.25), value: titleHeldBack)
                }
                .padding(.bottom, Phone.tabBarClearance)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(titleHeldBack)
            // The banner is allowed under the status bar and the nav bar —
            // artwork that stops short of the edges isn't a title card.
            .ignoresSafeArea(edges: .top)

            #if os(tvOS)
            // The folder's video is its intro: the whole screen, nothing over
            // it, then it fades into the page. Select skips it.
            if let intro = heroVideoURL, !heroVideoDone {
                Button {
                    withAnimation(.easeInOut(duration: 0.6)) { heroVideoDone = true }
                } label: {
                    ZStack {
                        Color.black
                        HeroVideo(
                            url: intro,
                            delay: .milliseconds(150),
                            onFinish: {
                                withAnimation(.easeInOut(duration: 0.9)) { heroVideoDone = true }
                            },
                            muted: !tmdb.trailerSound
                        )
                    }
                    .ignoresSafeArea()
                }
                .buttonStyle(BarePlatterStyle())
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(10)
            }
            #endif
        }
        #if os(tvOS)
        // Nothing over the intro, the tab bar included.
        .toolbar(titleHeldBack ? .hidden : .automatic, for: .tabBar)
        #endif
        .navigationTitle("")
        .platformInlineTitle()
        .platformHiddenNavigationBackground()
        .navigationDestination(item: $selected) { TitleDetail(selection: $0) }
        .task {
            await model.load(
                folder: open.folder,
                showAllTab: open.showAllTab,
                addons: addons
            )
        }
    }

    // MARK: Pieces

    /// The banner: artwork to all four edges, the folder's title treatment
    /// sitting on the floor of the frame, and a line of facts under it.
    private var banner: some View {
        // Measured rather than assumed. Every size below comes from the width
        // this banner was actually handed, so the title card fits an iPhone, a
        // half-width iPad window and a TV without a per-platform branch — and
        // cannot overhang an edge the way values read from the window-sized
        // `Phone` globals could when the two disagreed.
        GeometryReader { proxy in
            let width = proxy.size.width
            let padding = bannerPadding(for: width)
            let content = min(width - padding * 2, 680)

            ZStack(alignment: .bottom) {
                CinematicBackdrop(
                    url: (open.folder.heroBackdropURL ?? open.backdropURL)
                        .flatMap(URL.init(string:)),
                    animated: open.folder.animatedCoverURL,
                    height: bannerHeight,
                    // On the TV the video plays as a full-screen intro instead.
                    videoURL: {
                        #if os(tvOS)
                        nil
                        #else
                        heroVideoURL
                        #endif
                    }(),
                    onVideoFinish: { heroVideoDone = true }
                )

                VStack(spacing: 10) {
                    titleTreatment(content: content)
                }
                .overArtwork()
                // While the hero video plays the title stays out of the way,
                // then comes in as the video fades back to the still: a
                // slow fade with a small rise, so it settles into place
                // rather than snapping on.
                .opacity(titleHeldBack ? 0 : 1)
                .offset(y: titleHeldBack ? 14 : 0)
                .animation(.easeOut(duration: 1.0), value: titleHeldBack)
                .frame(width: content)
                .padding(.bottom, Phone.billboardBottomInset)
            }
            .frame(width: width, height: bannerHeight)
        }
        .frame(height: bannerHeight)
        // A stretchy header, as Home's billboard has: pulling down grows the
        // artwork rather than exposing the page behind it.
        .visualEffect { view, geometry in
            let minY = geometry.frame(in: .scrollView).minY
            let height = max(geometry.size.height, 1)
            return view
                .scaleEffect(minY > 0 ? 1 + minY / height : 1, anchor: .bottom)
                .offset(y: minY > 0 ? -minY / 2 : 0)
        }
    }

    /// Deep enough to be a title card rather than a strip of decoration, but
    /// never so deep the first row of artwork is pushed off the screen.
    private var bannerHeight: CGFloat { Phone.billboardHeight * 0.74 }

    /// The author's own logo when they set one — a title treatment is what a
    /// service leads with — and typeset large when they didn't.
    @ViewBuilder
    private func titleTreatment(content: CGFloat) -> some View {
        // Sized against the measure it sits in, never beyond it.
        let logoWidth = min(content, 360 * bannerScale(for: content))
        let logoHeight = min(110 * bannerScale(for: content), bannerHeight * 0.42)

        return Group {
            if let logo = open.folder.titleLogoURL, let url = URL(string: logo) {
                RemoteImage(url: url, contentMode: .fit)
                    .frame(width: logoWidth, height: logoHeight)
            } else {
                Text(open.folder.title)
                    .font(.system(size: titleSize(for: content), weight: .black))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: logoWidth)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The gutter grows with the window, the way the page's does.
    private func bannerPadding(for width: CGFloat) -> CGFloat {
        (16 * bannerScale(for: width)).rounded()
    }

    /// 1 at iPhone width, 2 by TV width, sliding in between so dragging a
    /// window edge resizes the title card rather than snapping it.
    private func bannerScale(for width: CGFloat) -> CGFloat {
        min(max((width / 390).squareRoot(), 1), 2)
    }

    private func titleSize(for width: CGFloat) -> CGFloat {
        (32 * bannerScale(for: width)).rounded()
    }

    /// What the folder actually holds, once it's loaded — the line a service
    /// puts under a title, rather than a second copy of the name.
    private var facts: [String] {
        var parts: [String] = []
        let catalogs = model.tabs.filter { $0.id != "__all" }.count
        if catalogs > 0 {
            parts.append(catalogs == 1 ? "1 catalog" : "\(catalogs) catalogs")
        }
        let titles = model.tabs.first { $0.id == "__all" }?.items.count
            ?? model.tabs.first?.items.count
            ?? 0
        if titles > 0 { parts.append("\(titles) titles") }
        return parts
    }

    /// The folder's filter, leading the rows it filters.
    private var filterBar: some View {
        HStack(spacing: 8) {
            filterButton
        }
        .padding(.leading, Phone.pagePadding)
    }

    /// One button carrying the current filter, with the three choices under
    /// it — a menu rather than three more chips, which would read as more
    /// catalogs in a row that is already catalogs.
    private var filterButton: some View {
        Menu {
            Picker("Filter", selection: $typeFilter) {
                ForEach(FolderTypeFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            #if os(tvOS)
            // The system's plain style lays a white platter under the label,
            // which hid its white text. Draw focus ourselves: a white pill
            // with dark text, like the app's other pills.
            FocusReader { isFocused in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(typeFilter.label)
                }
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(
                    isFocused ? Color.black
                        : (typeFilter == .all ? Color.white.opacity(0.85) : palette.onAccent)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background {
                    Capsule().fill(
                        isFocused ? AnyShapeStyle(Color.white)
                            : typeFilter == .all ? AnyShapeStyle(Color.white.opacity(0.14))
                            : AnyShapeStyle(palette.accent)
                    )
                }
                .scaleEffect(isFocused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
            }
            #else
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(typeFilter.label)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(typeFilter == .all ? .white.opacity(0.7) : palette.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(
                    typeFilter == .all
                        ? AnyShapeStyle(Color.white.opacity(0.08))
                        : AnyShapeStyle(palette.accent)
                )
            }
            #endif
        }
        .menuStyle(.button)
        #if os(tvOS)
        .buttonStyle(BarePlatterStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Each catalog as its own row under the banner, the way a streaming
    /// service lays out a hub, instead of tabs over one grid.
    @ViewBuilder
    private var rows: some View {
        let catalogs = model.tabs.filter { $0.id != "__all" }
        if catalogs.isEmpty {
            if model.isLoading {
                ForEach(0..<3, id: \.self) { _ in ShelfPlaceholder() }
            } else {
                note("Nothing in this folder could be loaded.")
            }
        } else if catalogs.count == 1, let tab = catalogs.first {
            // One catalog isn't a hub — a lone row under a banner reads as
            // unfinished — so its titles fill the page as a grid.
            single(tab)
        } else {
            ForEach(catalogs) { tab in
                switch tab.content {
                case .loading:
                    ShelfPlaceholder()
                case .failed:
                    VStack(alignment: .leading, spacing: 6) {
                        ShelfHeader(title: tab.label)
                        note("\(tab.label) didn't respond.")
                    }
                case .loaded(let all):
                    let items = all.filter { typeFilter.matches($0.type) }
                    if !items.isEmpty {
                        Shelf(title: tab.label, items: items) { item, _ in
                            let baseURL = model.baseURL(for: item, tab: tab)
                            PosterCard(item: item, addonBaseURL: baseURL) {
                                selected = MetaSelection(
                                    item: item,
                                    addonBaseURL: baseURL,
                                    related: items
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func single(_ tab: FolderTab) -> some View {
        switch tab.content {
        case .loading:
            ShelfPlaceholder()
        case .failed:
            note("\(tab.label) didn't respond.")
        case .loaded(let all):
            let items = all.filter { typeFilter.matches($0.type) }
            let cardWidth = (Phone.posterWidth * 0.88).rounded()
            #if os(macOS)
            // Fixed columns rather than adaptive ones, so each slot is exactly
            // the card's width and the grid can tell a card near the end of a
            // row how far its neighbours must slide left to give it room.
            let spacing = Phone.posterSpacing
            let columns = max(Int((gridWidth + spacing) / (cardWidth + spacing)), 1)
            let metrics = RowMetrics(
                columnsPerRow: columns,
                slotWidth: cardWidth,
                pitch: cardWidth + spacing
            )
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columns),
                alignment: .leading,
                spacing: 18
            ) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    let baseURL = model.baseURL(for: item, tab: tab)
                    PosterCard(item: item, addonBaseURL: baseURL, width: cardWidth) {
                        selected = MetaSelection(
                            item: item,
                            addonBaseURL: baseURL,
                            related: items
                        )
                    }
                    .standingAside(for: gridExpansion, slot: offset, metrics: metrics)
                }
            }
            .environment(gridExpansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .padding(.horizontal, Phone.pagePadding)
            #else
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardWidth), spacing: Phone.posterSpacing)],
                spacing: 18
            ) {
                ForEach(items) { item in
                    let baseURL = model.baseURL(for: item, tab: tab)
                    PosterCard(item: item, addonBaseURL: baseURL, width: cardWidth) {
                        selected = MetaSelection(
                            item: item,
                            addonBaseURL: baseURL,
                            related: items
                        )
                    }
                }
            }
            .padding(.horizontal, Phone.pagePadding)
            #endif
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Phone.pagePadding)
    }
}

#endif

