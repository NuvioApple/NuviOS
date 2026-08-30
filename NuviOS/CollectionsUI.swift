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

#if os(iOS)

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

    /// One tile at a time, the way one tile at a time holds focus on the TV.
    private var animating: String? {
        if let hovered { return hovered }
        guard isSettled else { return nil }
        // Until the shelf has been scrolled at all, the eye starts at its
        // leading edge, so that tile stands in for the centred one.
        return centered ?? collection.folders.first?.id
    }

    private var tileHeight: CGFloat { Phone.posterHeight * 0.82 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: collection.title, subtitle: collection.pinToTop ? "Pinned" : nil)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Phone.posterSpacing) {
                    ForEach(collection.folders) { folder in
                        Button { onOpen(folder) } label: {
                            tile(folder)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("\(folder.title), \(collection.title)")
                        .onHover { inside in
                            // Leaving a tile only clears the pointer if it
                            // hasn't already landed on its neighbour.
                            if inside { hovered = folder.id }
                            else if hovered == folder.id { hovered = nil }
                        }
                    }
                }
                .padding(.horizontal, Phone.pagePadding)
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

    private func tile(_ folder: CollectionFolder) -> some View {
        let size = FolderTile.size(folder.tileShape, height: tileHeight)
        return VStack(alignment: .leading, spacing: 8) {
            FolderCover(
                folder: folder,
                size: size,
                cornerRadius: Phone.posterRadius,
                isAnimating: animating == folder.id
            )

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

/// An opened folder: its catalogs as tabs over a grid of artwork.
struct FolderScreen: View {
    let open: OpenFolder
    let addons: AddonIndex

    @StateObject private var model = CollectionFolderModel()
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var selected: MetaSelection?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Phone.posterWidth), spacing: Phone.posterSpacing)]
    }

    private var tab: FolderTab? {
        guard model.tabs.indices.contains(model.selection) else { return nil }
        return model.tabs[model.selection]
    }

    var body: some View {
        ZStack(alignment: .top) {
            palette.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    banner

                    if model.tabs.count > 1 {
                        tabBar
                    }

                    if !model.skippedProviders.isEmpty {
                        note(
                            "\(model.skippedProviders.joined(separator: " and ")) sources in this folder need credentials this device doesn't have."
                        )
                    }

                    grid
                }
                .padding(.bottom, Phone.tabBarClearance)
            }
            .scrollIndicators(.hidden)
            // The banner is allowed under the status bar and the nav bar —
            // artwork that stops short of the edges isn't a title card.
            .ignoresSafeArea(edges: .top)
        }
        .navigationTitle(open.folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $selected) { DetailView(selection: $0) }
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
        ZStack(alignment: .bottomLeading) {
            CinematicBackdrop(
                url: (open.folder.heroBackdropURL ?? open.backdropURL)
                    .flatMap(URL.init(string:)),
                animated: open.folder.animatedCoverURL,
                height: bannerHeight
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(open.collectionTitle.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.62))

                titleTreatment

                if !facts.isEmpty {
                    Text(facts.joined(separator: "  ·  "))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
            }
            .overArtwork()
            .frame(width: Phone.billboardContentWidth, alignment: .leading)
            .padding(.horizontal, Phone.pagePadding)
            .padding(.bottom, Phone.billboardBottomInset)
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
    private var titleTreatment: some View {
        if let logo = open.folder.titleLogoURL, let url = URL(string: logo) {
            RemoteImage(url: url, contentMode: .fit)
                .frame(
                    maxWidth: Phone.billboardLogoWidth,
                    maxHeight: Phone.billboardLogoHeight * 0.8,
                    alignment: .leading
                )
        } else {
            Text(open.folder.title)
                .font(.system(size: Phone.billboardTitleSize, weight: .black))
                .tracking(-0.8)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                    Button { model.select(index) } label: {
                        Text(tab.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(index == model.selection ? palette.onAccent : .white.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                Capsule().fill(
                                    index == model.selection
                                        ? AnyShapeStyle(palette.accent)
                                        : AnyShapeStyle(Color.white.opacity(0.08))
                                )
                            }
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, Phone.pagePadding)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var grid: some View {
        if let tab {
            switch tab.content {
            case .loading:
                LazyVGrid(columns: columns, spacing: Phone.posterSpacing) {
                    ForEach(0..<9, id: \.self) { _ in PosterPlaceholder() }
                }
                .padding(.horizontal, Phone.pagePadding)
            case .failed:
                note("\(tab.label) didn't respond.")
            case .loaded(let items):
                LazyVGrid(columns: columns, spacing: Phone.posterSpacing + 6) {
                    ForEach(items) { item in
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
                .padding(.horizontal, Phone.pagePadding)
            }
        } else if model.isLoading {
            LazyVGrid(columns: columns, spacing: Phone.posterSpacing) {
                ForEach(0..<9, id: \.self) { _ in PosterPlaceholder() }
            }
            .padding(.horizontal, Phone.pagePadding)
        } else {
            note("Nothing in this folder could be loaded.")
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

// MARK: - tvOS

#if os(tvOS)

/// One collection as a focusable shelf of folder tiles.
struct CollectionShelfView: View {
    let collection: MediaCollection
    let metrics: LayoutMetrics
    let onOpen: (CollectionFolder) -> Void

    private var tileHeight: CGFloat { metrics.posterHeight * 0.78 }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.lerp(8, 12)) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(collection.title)
                    .font(.system(size: metrics.rowTitleSize, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)

                Text("COLLECTION")
                    .font(.system(size: metrics.lerp(10, 14), weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, metrics.lerp(7, 10))
                    .padding(.vertical, metrics.lerp(3, 4))
                    .background(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, metrics.pagePadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.posterSpacing) {
                    ForEach(collection.folders) { folder in
                        Button { onOpen(folder) } label: {
                            EmptyView()
                        }
                        .buttonStyle(
                            FolderTileStyle(
                                folder: folder,
                                metrics: metrics,
                                height: tileHeight
                            )
                        )
                        .accessibilityLabel("\(folder.title), \(collection.title)")
                    }
                }
                .padding(.horizontal, metrics.pagePadding)
                .padding(.vertical, metrics.posterFocusPadding)
            }
            .scrollClipDisabled()
        }
    }
}

/// The folder tile's whole look, including the focus lift the TV shell uses
/// everywhere else.
private struct FolderTileStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    let folder: CollectionFolder
    let metrics: LayoutMetrics
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let size = FolderTile.size(folder.tileShape, height: height)

        return FocusReader { isFocused in
            VStack(alignment: .leading, spacing: metrics.lerp(6, 10)) {
                FolderCover(
                    folder: folder,
                    size: size,
                    cornerRadius: metrics.posterCornerRadius,
                    isAnimating: isFocused
                )
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.posterCornerRadius, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.white.opacity(0.95) : .clear,
                            lineWidth: metrics.lerp(2, 4)
                        )
                }
                .shadow(
                    color: isFocused ? palette.accent.opacity(0.5) : .black.opacity(0.5),
                    radius: isFocused ? metrics.lerp(14, 34) : 10,
                    y: isFocused ? metrics.lerp(8, 20) : 6
                )

                if !folder.hideTitle {
                    Text(folder.title)
                        .font(.system(size: metrics.lerp(12, 19), weight: .semibold))
                        .foregroundStyle(.white.opacity(isFocused ? 1 : 0.7))
                        .lineLimit(1)
                        .frame(width: size.width, alignment: .leading)
                }
            }
            .scaleEffect(
                configuration.isPressed ? 0.97 : (isFocused ? metrics.posterFocusScale : 1)
            )
            .zIndex(isFocused ? 1 : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.74), value: isFocused)
        }
    }
}

/// An opened folder on the TV: the catalogs it bundles, one shelf each, over
/// the folder's own artwork.
struct FolderView: View {
    let open: OpenFolder
    let addons: AddonIndex

    @StateObject private var model = CollectionFolderModel()
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var selected: MetaSelection?

    var body: some View {
        GeometryReader { proxy in
            let metrics = LayoutMetrics(width: proxy.size.width, height: proxy.size.height)

            ZStack {
                NuvioBackground(intensity: 0.85)
                backdrop(metrics)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                        header(metrics)

                        if !model.skippedProviders.isEmpty {
                            Text("\(model.skippedProviders.joined(separator: " and ")) sources in this folder need credentials this device doesn't have.")
                                .font(.system(size: metrics.lerp(13, 20)))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.horizontal, metrics.pagePadding)
                        }

                        if model.tabs.isEmpty {
                            if model.isLoading {
                                ForEach(0..<2, id: \.self) { _ in
                                    shelfSkeleton(metrics)
                                }
                            } else {
                                Text("Nothing in this folder could be loaded.")
                                    .font(.system(size: metrics.lerp(14, 22)))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .padding(.horizontal, metrics.pagePadding)
                            }
                        } else {
                            ForEach(shelves) { tab in
                                shelf(tab, metrics: metrics)
                            }
                        }
                    }
                    .padding(.bottom, metrics.lerp(40, 90))
                }
                .scrollClipDisabled()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await model.load(folder: open.folder, showAllTab: open.showAllTab, addons: addons)
        }
        .fullScreenCover(item: $selected) { selection in
            MetaDetailView(selection: selection)
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
    }

    /// The TV lays every catalog out as its own shelf rather than hiding them
    /// behind tabs — a remote scrolls further more easily than it switches
    /// tabs — so the merged "All" tab is left out here.
    private var shelves: [FolderTab] { model.tabs.filter { $0.id != "__all" } }

    @ViewBuilder
    private func backdrop(_ metrics: LayoutMetrics) -> some View {
        if let backdrop = open.folder.heroBackdropURL ?? open.backdropURL,
           let url = URL(string: backdrop) {
            VStack {
                RemoteImage(url: url)
                    .frame(height: metrics.heroHeight * 0.8)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.2), palette.background],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
        }
    }

    private func header(_ metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.lerp(6, 10)) {
            Text(open.collectionTitle.uppercased())
                .font(.system(size: metrics.lerp(11, 16), weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.5))

            if let logo = open.folder.titleLogoURL, let url = URL(string: logo) {
                RemoteImage(url: url, contentMode: .fit)
                    .frame(
                        maxWidth: metrics.heroLogoMaxWidth,
                        maxHeight: metrics.heroLogoMaxHeight * 0.6,
                        alignment: .leading
                    )
            } else {
                Text(open.folder.title)
                    .font(.system(size: metrics.heroTitleSize * 0.7, weight: .black))
                    .foregroundStyle(.white)
            }
        }
        .overArtwork()
        .padding(.horizontal, metrics.pagePadding)
        .padding(.top, metrics.lerp(20, 48))
    }

    @ViewBuilder
    private func shelf(_ tab: FolderTab, metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.lerp(8, 12)) {
            Text(tab.label)
                .font(.system(size: metrics.rowTitleSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, metrics.pagePadding)

            switch tab.content {
            case .loading:
                skeletonRow(metrics)
            case .failed:
                Text("This catalog didn't respond.")
                    .font(.system(size: metrics.lerp(13, 20)))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, metrics.pagePadding)
            case .loaded(let items):
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: metrics.posterSpacing) {
                        ForEach(items) { item in
                            let baseURL = model.baseURL(for: item, tab: tab)
                            PosterCard(item: item, addonBaseURL: baseURL, metrics: metrics) {
                                selected = MetaSelection(item: item, addonBaseURL: baseURL)
                            }
                        }
                    }
                    .padding(.horizontal, metrics.pagePadding)
                    .padding(.vertical, metrics.posterFocusPadding)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func shelfSkeleton(_ metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.lerp(8, 14)) {
            SkeletonBlock(cornerRadius: 8)
                .frame(width: metrics.lerp(140, 300), height: metrics.lerp(18, 30))
                .padding(.horizontal, metrics.pagePadding)
            skeletonRow(metrics)
        }
    }

    private func skeletonRow(_ metrics: LayoutMetrics) -> some View {
        HStack(spacing: metrics.posterSpacing) {
            ForEach(0..<6, id: \.self) { _ in
                SkeletonBlock(cornerRadius: metrics.posterCornerRadius)
                    .frame(width: metrics.posterWidth, height: metrics.posterHeight)
            }
        }
        .padding(.horizontal, metrics.pagePadding)
    }
}

#endif
