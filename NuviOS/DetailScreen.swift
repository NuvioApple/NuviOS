import SwiftUI

/// A title's page: full-bleed backdrop, title treatment, the facts, and the
/// long-form detail underneath — the shape every streaming service uses.
struct MetaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    let selection: MetaSelection

    @State private var detail: MetaDetail?
    @State private var failed = false
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
        }
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
                Button(detail?.seasons.isEmpty == false ? "Episodes" : "Play") {
                    isPickingStream = true
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

    @ViewBuilder
    private func credits(_ metrics: LayoutMetrics) -> some View {
        if let cast = detail?.cast, !cast.isEmpty {
            VStack(alignment: .leading, spacing: metrics.isCompact ? 10 : 18) {
                SectionLabel(text: "Cast", metrics: metrics)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: metrics.isCompact ? 10 : 18) {
                        ForEach(cast.prefix(12), id: \.self) { name in
                            CastBubble(name: name, metrics: metrics)
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

/// Addons send cast as plain names, so the avatar is a monogram rather than a
/// broken image well.
private struct CastBubble: View {
    @Environment(\.palette) private var palette
    let name: String
    let metrics: LayoutMetrics

    private var size: CGFloat { metrics.isCompact ? 60 : 118 }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        VStack(spacing: metrics.isCompact ? 6 : 12) {
            Text(initials)
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [palette.accent.opacity(0.35), palette.accentVariant.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
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
