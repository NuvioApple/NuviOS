import SwiftUI

/// A title's page: full-bleed backdrop, title treatment, the facts, and the
/// long-form detail underneath — the shape every streaming service uses.
struct MetaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @EnvironmentObject private var tmdb: TmdbSettings

    let selection: MetaSelection

    @State private var detail: MetaDetail?
    @State private var failed = false
    @State private var isPickingStream = false
    /// The episode the viewer picked from the inline list, if any.
    @State private var playingVideo: MetaVideo?
    @State private var chosenSeason: Int?
    /// Photos for the cast list, keyed by name — `nil` until TMDB answers (or
    /// there's no key to ask it with), so the bubbles fall back to monograms
    /// rather than waiting on a blank space.
    @State private var castPhotos: [String: URL] = [:]

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

    var body: some View {
        GeometryReader { proxy in
            let metrics = LayoutMetrics(width: proxy.size.width, height: proxy.size.height)

            ZStack(alignment: .top) {
                NuvioBackground(intensity: 0.7)

                backdrop(metrics)

                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.isCompact ? 22 : 34) {
                        // Pushes the copy down so it sits in the dark half of
                        // the backdrop rather than across the artwork.
                        Color.clear
                            .frame(height: metrics.detailBackdropHeight * 0.52)

                        titleTreatment(metrics)
                        facts(metrics)
                        actions(metrics)
                        synopsis(metrics)
                        episodes(metrics)
                        credits(metrics)
                        factSheet(metrics)
                    }
                    .padding(.horizontal, metrics.pagePadding)
                    .padding(.bottom, metrics.isCompact ? 48 : 100)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()
            }
        }
        .preferredColorScheme(.dark)
        .platformFullScreenCover(isPresented: $isPickingStream) {
            StreamPicker(selection: selection, detail: detail)
        }
        .platformFullScreenCover(item: $playingVideo) { video in
            StreamPicker(selection: selection, detail: detail, video: video)
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
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
            await loadCastPhotos()
        }
    }

    /// The addon's cast is just names, so photos have to be matched back onto
    /// those names from elsewhere. TMDB's credits (when the viewer has a key
    /// configured) come first since they're a real, unambiguous match; TMDB
    /// covers no cast, or names it left out, get an image from Wikipedia
    /// instead — a key-free name search, so the cast strip has photos even
    /// with no key set up at all.
    private func loadCastPhotos() async {
        let names = detail?.cast.prefix(12) ?? []
        guard !names.isEmpty else { return }

        var byName: [String: URL] = [:]

        if let members = await CastService.shared.cast(for: item, apiKey: tmdb.effectiveAPIKey) {
            for member in members where member.profileURL != nil {
                byName[member.name.lowercased()] = member.profileURL
            }
            castPhotos = byName
        }

        let missing = names.filter { byName[$0.lowercased()] == nil }
        guard !missing.isEmpty else { return }

        await withTaskGroup(of: (String, URL?).self) { group in
            for name in missing {
                group.addTask { (name, await WikipediaCastService.shared.photo(forName: name)) }
            }
            for await (name, url) in group {
                if let url { byName[name.lowercased()] = url }
            }
        }
        castPhotos = byName
    }

    // MARK: Backdrop

    private func backdrop(_ metrics: LayoutMetrics) -> some View {
        RemoteImage(url: backdropURL) {
            AnyView(Color.white.opacity(0.04))
        }
        .frame(height: metrics.detailBackdropHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay {
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.5), location: 0),
                        .init(color: .black.opacity(0.15), location: 0.22),
                        .init(color: palette.background.opacity(0.75), location: 0.66),
                        .init(color: palette.background, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    colors: [palette.background.opacity(0.85), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Blocks

    @ViewBuilder
    private func titleTreatment(_ metrics: LayoutMetrics) -> some View {
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
                default:
                    typesetTitle(metrics)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overArtwork()
        } else {
            typesetTitle(metrics)
        }
    }

    private func typesetTitle(_ metrics: LayoutMetrics) -> some View {
        Text(detail?.name ?? item.name)
            .font(.system(size: metrics.isCompact ? 34 : 72, weight: .black))
            .tracking(-1.4)
            .foregroundStyle(.white)
            .lineLimit(3)
            .minimumScaleFactor(0.55)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: metrics.isCompact ? .infinity : metrics.width * 0.72, alignment: .leading)
            .overArtwork()
    }

    private func facts(_ metrics: LayoutMetrics) -> some View {
        HStack(spacing: metrics.isCompact ? 8 : 12) {
            MetaChip(text: HomeViewModel.typeLabel(item.type), emphasised: true)

            if let year = (detail?.releaseInfo ?? item.releaseInfo)?.trimmed, !year.isEmpty {
                MetaChip(text: year)
            }
            if let runtime = detail?.runtime?.trimmed, !runtime.isEmpty {
                MetaChip(text: runtime)
            }
            if let rating = (detail?.imdbRating ?? item.imdbRating)?.trimmed, !rating.isEmpty {
                RatingChip(rating: rating)
            }
            Spacer(minLength: 0)
        }
        .scaleEffect(metrics.isCompact ? 0.8 : 1, anchor: .leading)
    }

    private func actions(_ metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.isCompact ? 10 : 16) {
            HStack(spacing: metrics.isCompact ? 12 : 20) {
                Button(playLabel) {
                    // Series pick up where the inline list leaves off: the
                    // button plays, it no longer opens a picker.
                    if let first = firstEpisode {
                        playingVideo = first
                    } else {
                        isPickingStream = true
                    }
                }
                .buttonStyle(
                    NuvioButtonStyle(kind: .prominent, icon: "play.fill", compact: metrics.isCompact)
                )

                Button("Back to browsing") { dismiss() }
                    .buttonStyle(
                        NuvioButtonStyle(kind: .glass, icon: "chevron.left", compact: metrics.isCompact)
                    )
            }
        }
    }

    @ViewBuilder
    private func synopsis(_ metrics: LayoutMetrics) -> some View {
        let text = (detail?.description ?? item.description)?.trimmed

        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: metrics.isCompact ? 15 : 25))
                .lineSpacing(metrics.isCompact ? 3 : 7)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: metrics.isCompact ? .infinity : min(metrics.width * 0.62, 1250), alignment: .leading)
        } else if failed {
            Text("Couldn't load details for this title.")
                .font(.system(size: metrics.isCompact ? 15 : 22))
                .foregroundStyle(.white.opacity(0.5))
        } else if detail == nil {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3, id: \.self) { row in
                    SkeletonBlock(cornerRadius: 6)
                        .frame(
                            width: metrics.isCompact ? (row == 2 ? 180 : 300) : (row == 2 ? 500 : 900),
                            height: metrics.isCompact ? 12 : 20
                        )
                }
            }
        }
    }

    private var firstEpisode: MetaVideo? {
        detail?.seasons.first?.episodes.first
    }

    private var playLabel: String {
        guard let code = firstEpisode?.code else { return "Play" }
        return "Play \(code)"
    }

    // MARK: Episodes

    /// The episode list lives on the page, above the cast, rather than behind
    /// a modal: picking an episode is the main thing a series page is for.
    @ViewBuilder
    private func episodes(_ metrics: LayoutMetrics) -> some View {
        let seasons = detail?.seasons ?? []

        if !seasons.isEmpty {
            let active = chosenSeason ?? seasons.first?.season
            let list = seasons.first { $0.season == active }?.episodes ?? []

            VStack(alignment: .leading, spacing: metrics.isCompact ? 10 : 18) {
                SectionLabel(text: "Episodes", metrics: metrics)

                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: metrics.isCompact ? 8 : 12) {
                            ForEach(seasons, id: \.season) { season in
                                SeasonPill(
                                    label: season.season == 0 ? "Specials" : "Season \(season.season)",
                                    selected: season.season == active,
                                    metrics: metrics
                                ) {
                                    chosenSeason = season.season
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollClipDisabled()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: metrics.isCompact ? 12 : 22) {
                        ForEach(list) { episode in
                            EpisodeCard(
                                episode: episode,
                                baseURL: selection.addonBaseURL,
                                metrics: metrics
                            ) {
                                playingVideo = episode
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private func credits(_ metrics: LayoutMetrics) -> some View {
        if let cast = detail?.cast, !cast.isEmpty {
            VStack(alignment: .leading, spacing: metrics.isCompact ? 10 : 18) {
                SectionLabel(text: "Cast", metrics: metrics)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: metrics.isCompact ? 10 : 18) {
                        ForEach(cast.prefix(12), id: \.self) { name in
                            CastBubble(name: name, photoURL: castPhotos[name.lowercased()], metrics: metrics)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private func factSheet(_ metrics: LayoutMetrics) -> some View {
        let entries = factEntries

        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: metrics.isCompact ? 10 : 18) {
                SectionLabel(text: "Details", metrics: metrics)

                VStack(alignment: .leading, spacing: metrics.isCompact ? 8 : 14) {
                    ForEach(entries, id: \.label) { entry in
                        HStack(alignment: .top, spacing: metrics.isCompact ? 12 : 28) {
                            Text(entry.label.uppercased())
                                .font(.system(size: metrics.isCompact ? 10 : 15, weight: .heavy))
                                .tracking(1.1)
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: metrics.isCompact ? 78 : 190, alignment: .leading)

                            Text(entry.value)
                                .font(.system(size: metrics.isCompact ? 13 : 20, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(metrics.isCompact ? 18 : 32)
                .frame(maxWidth: metrics.isCompact ? .infinity : min(metrics.width * 0.66, 1250), alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
            }
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
        if let runtime = detail?.runtime?.trimmed, !runtime.isEmpty {
            entries.append(("Runtime", runtime))
        }
        if let release = (detail?.releaseInfo ?? item.releaseInfo)?.trimmed, !release.isEmpty {
            entries.append(("Released", release))
        }
        return entries
    }
}

/// A section heading with the accent rule streaming apps use to break up a
/// long page.
private struct SectionLabel: View {
    @Environment(\.palette) private var palette
    let text: String
    let metrics: LayoutMetrics

    var body: some View {
        HStack(spacing: 12) {
            Capsule()
                .fill(palette.accentBrush)
                .frame(width: metrics.isCompact ? 3 : 5, height: metrics.isCompact ? 18 : 30)

            Text(text)
                .font(.system(size: metrics.isCompact ? 18 : 30, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// Addons send cast as plain names with no photos — `photoURL`, when TMDB has
/// matched one, is what turns this from a monogram into an actual portrait.
private struct CastBubble: View {
    @Environment(\.palette) private var palette
    let name: String
    var photoURL: URL?
    let metrics: LayoutMetrics

    private var size: CGFloat { metrics.isCompact ? 60 : 118 }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    @ViewBuilder private var monogram: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [palette.accent.opacity(0.35), palette.accentVariant.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    var body: some View {
        VStack(spacing: metrics.isCompact ? 6 : 12) {
            Group {
                // `AsyncImage(url: nil)` reports `.empty`, not `.failure`, so
                // the monogram fallback only fires on a real load failure —
                // no photo at all has to be handled up front instead.
                if let photoURL {
                    RemoteImage(url: photoURL, contentMode: .fill) { AnyView(monogram) }
                } else {
                    monogram
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))

            Text(name)
                .font(.system(size: metrics.isCompact ? 11 : 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size * 1.35)
        }
    }
}

/// A season selector chip. Plain button style so tvOS still draws focus on the
/// shape rather than a system bezel.
private struct SeasonPill: View {
    @Environment(\.palette) private var palette
    let label: String
    let selected: Bool
    let metrics: LayoutMetrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: metrics.isCompact ? 13 : 19, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(0.72))
                .padding(.horizontal, metrics.isCompact ? 14 : 22)
                .padding(.vertical, metrics.isCompact ? 8 : 12)
                .background(
                    Capsule().fill(
                        selected ? palette.accent.opacity(0.85) : Color.white.opacity(0.10)
                    )
                )
                .overlay(Capsule().stroke(.white.opacity(selected ? 0.25 : 0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// One episode: the still, the number and title, and as much of the synopsis
/// as fits — the card shape the rest of the app already uses for artwork.
private struct EpisodeCard: View {
    @Environment(\.palette) private var palette
    let episode: MetaVideo
    let baseURL: String
    let metrics: LayoutMetrics
    let action: () -> Void

    private var width: CGFloat { metrics.isCompact ? 210 : 380 }

    private var thumbnailURL: URL? {
        guard let thumbnail = episode.thumbnail?.trimmed, !thumbnail.isEmpty else { return nil }
        return AddonClient.resolve(thumbnail, relativeTo: baseURL)
    }

    private var heading: String {
        [episode.code, episode.title?.trimmed.nilWhenEmpty]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
            .nilWhenEmpty ?? episode.displayTitle
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: metrics.isCompact ? 8 : 12) {
                ZStack {
                    RemoteImage(url: thumbnailURL) {
                        AnyView(
                            ZStack {
                                Color.white.opacity(0.05)
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: width * 0.14))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                        )
                    }
                    .frame(width: width, height: width * 9 / 16)
                    .clipped()

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: metrics.isCompact ? 30 : 48))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 8)
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: metrics.isCompact ? 12 : 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.isCompact ? 12 : 18, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )

                Text(heading)
                    .font(.system(size: metrics.isCompact ? 13 : 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let overview = episode.overview?.trimmed.nilWhenEmpty {
                    Text(overview)
                        .font(.system(size: metrics.isCompact ? 11 : 16))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
