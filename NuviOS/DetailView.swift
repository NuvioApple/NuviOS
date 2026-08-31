#if os(iOS) || os(macOS) || os(tvOS)
import SwiftUI

/// A title's page on the phone.
///
/// The TV keeps `MetaDetailView`, which is laid out in TV metrics; this is the
/// same information in the shape the streaming apps use on a phone: artwork to
/// every edge, the title's own logo over it, a row of round actions, then the
/// facts, the cast, and more like it.
struct DetailView: View {
    let selection: MetaSelection

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var detail: MetaDetail?
    @State private var failed = false
    @State private var synopsisExpanded = false
    @State private var scrollProgress: Double = 0
    @State private var related: MetaSelection?
    @State private var isPickingStream = false

    private var item: MetaItem { selection.item }

    private var backdropURL: URL? {
        AddonClient.resolve(
            detail?.background ?? item.background ?? detail?.poster ?? item.poster,
            relativeTo: selection.addonBaseURL
        )
    }

    private var logoURL: URL? {
        guard let logo = (detail?.logo ?? item.logo)?.trimmed, !logo.isEmpty else { return nil }
        return AddonClient.resolve(logo, relativeTo: selection.addonBaseURL)
    }

    private var synopsis: String? {
        (detail?.description ?? item.description)?.trimmed.nilWhenEmpty
    }

    private var isSaved: Bool { library.contains(item) }

    /// Titles from the same row that share a genre — the ordinary "because you
    /// opened this" row, computed from what is already in memory.
    private var moreLikeThis: [MetaItem] {
        let genres = Set((detail?.genres.isEmpty == false ? detail!.genres : item.genres)
            .map { $0.lowercased() })
        let others = selection.related.filter { $0.id != item.id }
        guard !genres.isEmpty else { return Array(others.prefix(12)) }
        let matching = others.filter { candidate in
            candidate.genres.contains { genres.contains($0.lowercased()) }
        }
        return Array((matching.isEmpty ? others : matching).prefix(12))
    }

    var body: some View {
        ZStack(alignment: .top) {
            palette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    artwork
                    actions
                    synopsisBlock
                    factSheet
                    castBlock
                    moreLikeThisBlock
                }
                .padding(.bottom, 48)
            }
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            .trackingScrollProgress(over: 260, into: $scrollProgress)

            // Our own bar: the system one can't be transparent over artwork and
            // then solid over the facts without fighting the scroll edge effect.
            navigationBar
        }
        .platformHiddenNavigationBar()
        .navigationDestination(item: $related) { selection in
            DetailView(selection: selection)
        }
        .sheet(isPresented: $isPickingStream) {
            StreamPicker(selection: selection, detail: detail)
                .platformSheetSizing()
        }
        .task {
            do {
                detail = try await AddonClient().meta(
                    baseURL: selection.addonBaseURL,
                    type: item.type,
                    id: item.id
                )
            } catch {
                failed = true
            }
        }
    }

    // MARK: Chrome

    private var navigationBar: some View {
        FloatingTopBar(progress: scrollProgress) {
            AnyView(
                HStack(spacing: 10) {
                    // The Mac already has a back button, in the window's own
                    // toolbar, and `platformHiddenNavigationBar` cannot take it
                    // away there — it hides an iOS navigation bar. Drawing this
                    // one too put two back chevrons on screen, one above the
                    // other. The Mac keeps the system button, which is where a
                    // Mac user looks for it, and this bar carries the title.
                    #if !os(macOS)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .glassEffect(.regular, in: .circle)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Back")
                    #endif

                    Text(detail?.name ?? item.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .opacity(scrollProgress)
                }
            )
        } trailing: {
            EmptyView()
        }
    }

    // MARK: Artwork

    /// The backdrop, the title treatment in its dark lower third, and the
    /// facts line under it — one composed block that melts into the page.
    private var artwork: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            titleTreatment

            Text(factsLine)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: Phone.readableWidth)
        .frame(maxWidth: .infinity)
        .frame(height: Phone.detailArtworkHeight)
        .background {
            ZStack {
                RemoteImage(url: backdropURL) {
                    AnyView(Color.white.opacity(0.05))
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.30), location: 0),
                        .init(color: .black.opacity(0.05), location: 0.32),
                        .init(color: .black.opacity(0.62), location: 0.7),
                        .init(color: palette.background.opacity(0.94), location: 0.92),
                        .init(color: palette.background, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        // The artwork is the only thing allowed past the safe area; the clip
        // keeps a `.fill` image from widening the page.
        .clipped()
        .visualEffect { view, geometry in
            let minY = geometry.frame(in: .scrollView).minY
            let height = max(geometry.size.height, 1)
            return view
                .scaleEffect(minY > 0 ? 1 + minY / height : 1, anchor: .bottom)
                .offset(y: minY > 0 ? -minY / 2 : 0)
        }
    }

    private var factsLine: String {
        var parts: [String] = []
        if let year = (detail?.releaseInfo ?? item.releaseInfo)?.trimmed.nilWhenEmpty {
            parts.append(year)
        }
        parts.append(HomeViewModel.typeLabel(item.type))
        if let runtime = detail?.runtime?.trimmed.nilWhenEmpty { parts.append(runtime) }
        if let rating = (detail?.imdbRating ?? item.imdbRating)?.trimmed.nilWhenEmpty {
            parts.append("★ \(rating)")
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var titleTreatment: some View {
        if let logoURL {
            AsyncImage(url: logoURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    typesetTitle
                }
            }
            .frame(maxWidth: min(300 * Phone.scale, Phone.readableWidth), maxHeight: 120 * Phone.scale)
        } else {
            typesetTitle
        }
    }

    private var typesetTitle: some View {
        Text(detail?.name ?? item.name)
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
    }

    // MARK: Actions

    /// The action row, led by Play. A series opens on its episode list, a
    /// movie straight on its sources — the sheet decides which from the meta
    /// it was handed, so the button reads the same either way.
    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                isPickingStream = true
            } label: {
                Label(playTitle, systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)

            HStack(spacing: 34) {
                DetailAction(
                    title: isSaved ? "In My List" : "My List",
                    systemImage: isSaved ? "checkmark" : "plus"
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        library.toggle(item, addonBaseURL: selection.addonBaseURL)
                    }
                }

                PlatformShareButton(text: shareText)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: Phone.readableWidth)
        .frame(maxWidth: .infinity)
    }

    /// Series lead with the episode step, so the button says so.
    private var playTitle: String {
        (detail?.seasons.isEmpty == false) ? "Episodes" : "Play"
    }

    private var shareText: String {
        let name = detail?.name ?? item.name
        if item.id.hasPrefix("tt") {
            return "\(name) — https://www.imdb.com/title/\(item.id)/"
        }
        return name
    }

    // MARK: Blocks

    @ViewBuilder
    private var synopsisBlock: some View {
        if let synopsis {
            VStack(alignment: .leading, spacing: 6) {
                Text(synopsis)
                    .font(.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(synopsisExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)

                Button(synopsisExpanded ? "Less" : "More") {
                    withAnimation(.easeInOut(duration: 0.2)) { synopsisExpanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .tint(palette.accent)
            }
            .frame(maxWidth: Phone.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
        } else if failed {
            Text("Couldn't load details for this title.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var castBlock: some View {
        if let cast = detail?.cast, !cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(cast.prefix(12), id: \.self) { name in
                            CastChip(name: name)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    @ViewBuilder
    private var moreLikeThisBlock: some View {
        let items = moreLikeThis
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("More Like This")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Phone.posterSpacing) {
                        ForEach(items) { candidate in
                            PosterCard(
                                item: candidate,
                                addonBaseURL: selection.addonBaseURL,
                                width: (Phone.posterWidth * 0.88).rounded()
                            ) {
                                related = MetaSelection(
                                    item: candidate,
                                    addonBaseURL: selection.addonBaseURL,
                                    related: selection.related
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    @ViewBuilder
    private var factSheet: some View {
        let entries = factEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(entries, id: \.label) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.label.uppercased())
                            .font(.caption2.weight(.heavy))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.4))

                        Text(entry.value)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 22)
            .frame(maxWidth: Phone.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
        }
    }

    private var factEntries: [(label: String, value: String)] {
        var entries: [(String, String)] = []

        let genres = detail?.genres.isEmpty == false ? detail!.genres : item.genres
        if !genres.isEmpty {
            entries.append(("Genres", genres.joined(separator: " · ")))
        }
        if let director = detail?.director, !director.isEmpty {
            entries.append((director.count > 1 ? "Directors" : "Director", director.joined(separator: ", ")))
        }
        if let release = (detail?.releaseInfo ?? item.releaseInfo)?.trimmed.nilWhenEmpty {
            entries.append(("Released", release))
        }
        return entries
    }
}

// MARK: - Pieces

/// A stacked icon-over-label control, the shape the streaming apps use for
/// everything that isn't Play.
private struct DetailAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 70)
        }
        .buttonStyle(.pressable)
    }
}

/// Addons send cast as plain names, so the avatar is a monogram rather than a
/// broken image well.
private struct CastChip: View {
    @Environment(\.palette) private var palette
    let name: String

    private var initials: String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(initials)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 56, height: 56)
                .background {
                    Circle().fill(
                        LinearGradient(
                            colors: [
                                palette.accent.opacity(0.35),
                                palette.accentVariant.opacity(0.2),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
                .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1) }

            Text(name)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 76)
        }
    }
}
#endif
