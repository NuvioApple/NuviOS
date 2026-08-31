import SwiftUI
import Combine

// The shelf that knows where you got to.
//
// A progress row from the backend is only ids and a position — no title, no
// artwork. The addons hold those, so each entry is looked up against whichever
// installed addon answers for it, and the two are put together here.

/// One card: the title, where it got to, and which addon can open it again.
struct ContinueWatchingItem: Identifiable, Equatable {
    let item: MetaItem
    let addonBaseURL: String
    let progress: WatchProgressEntry
    /// The episode's own title, when the addon named it. `S2 E7 · Chikara`
    /// tells a viewer far more about where they are than a number alone.
    var episodeTitle: String?

    var id: String { "\(progress.contentType)|\(progress.videoID.nilWhenEmpty ?? progress.contentID)" }

    /// `S2 E7`, for an episode.
    var episodeLabel: String? {
        guard let season = progress.season, let episode = progress.episode else { return nil }
        return "S\(season) E\(episode)"
    }

    /// `24m left` — what a viewer actually wants to know before committing.
    var remainingLabel: String? {
        let remaining = progress.durationSeconds - progress.positionSeconds
        guard remaining > 60 else { return nil }
        let minutes = Int(remaining / 60)
        if minutes < 60 { return "\(minutes)m left" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h left" : "\(hours)h \(rest)m left"
    }
}

/// Builds the shelf: reads the account's progress, then finds each title.
///
/// A loader rather than a store: the home view model already publishes the
/// screen's state, and a second observable object beside it only creates two
/// places for the same shelf to be out of date.
enum ContinueWatchingLoader {
    /// Enough to fill the shelf without asking every addon about forty titles.
    private static let maxItems = 12

    /// Reads what this profile is part-way through and puts artwork to it.
    ///
    /// Quiet on failure, in every direction: a backend that won't answer, a
    /// guest with no account, an addon that doesn't know a title — none of
    /// those are worth an error on a home screen that has plenty else to show.
    /// The shelf simply isn't there.
    static func load(
        session: AppSession,
        profile: Profile,
        addonURLs: [String]
    ) async -> [ContinueWatchingItem] {
        guard !addonURLs.isEmpty else { return [] }

        var entries: [WatchProgressEntry] = []

        // The account's rows first: they carry what every device on this
        // account watched, which is the point of the shelf.
        if case .signedIn = session.state,
           let configuration = await session.configuration,
           let token = await session.validAccessToken() {
            entries = (try? await WatchProgressDirectory.inProgress(
                configuration: configuration,
                accessToken: token,
                profileID: profile.effectiveAddonProfileID
            )) ?? []

            // The position the backend holds is the truth about where this
            // account got to; the player reads its resume point locally, so the
            // two are reconciled here rather than at press-time. Without this,
            // a film paused on the television would open at zero here while the
            // card said forty minutes in.
            for entry in entries {
                PlaybackProgress.adopt(
                    key: entry.resumeKey,
                    seconds: entry.positionSeconds,
                    duration: entry.durationSeconds,
                    updated: Date(timeIntervalSince1970: Double(entry.lastWatched) / 1000)
                )
            }
        }

        // Then whatever this device watched by itself. A guest has no account
        // rows at all, and a signed-in viewer whose progress lives in Trakt or
        // Simkl rather than the backend has none either — but both have this.
        entries = merged(entries, with: localEntries())
        print("[continue-watching] \(entries.count) title(s) to show")
        guard !entries.isEmpty else { return [] }

        return await resolve(
            entries: Array(entries.prefix(maxItems)),
            addonURLs: addonURLs
        )
    }

    /// This device's own resume points, in the same shape as the account's.
    private static func localEntries() -> [WatchProgressEntry] {
        PlaybackProgress.inProgress().compactMap { key, entry in
            guard var built = WatchProgressSync.entry(
                resumeKey: key,
                seconds: entry.seconds,
                duration: entry.duration
            ) else { return nil }
            built.lastWatched = Int64(entry.updated.timeIntervalSince1970 * 1000)
            return built
        }
    }

    /// Folds two lists into one, newest write per title winning.
    private static func merged(
        _ remote: [WatchProgressEntry],
        with local: [WatchProgressEntry]
    ) -> [WatchProgressEntry] {
        var byContent: [String: WatchProgressEntry] = [:]
        for entry in remote + local {
            let key = "\(entry.contentType)|\(entry.contentID)"
            if let existing = byContent[key], existing.lastWatched >= entry.lastWatched { continue }
            byContent[key] = entry
        }
        return byContent.values.sorted { $0.lastWatched > $1.lastWatched }
    }

    /// Looks each entry up, keeping the backend's order.
    ///
    /// Which addon serves a given title isn't recorded with the progress, so
    /// every installed addon is asked at once and the first real answer wins —
    /// the same shape as a stream fan-out, and for the same reason.
    private static func resolve(
        entries: [WatchProgressEntry],
        addonURLs: [String]
    ) async -> [ContinueWatchingItem] {
        let client = AddonClient()
        return await withTaskGroup(of: (Int, ContinueWatchingItem?).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    (index, await lookUp(entry: entry, addonURLs: addonURLs, client: client))
                }
            }
            var found: [Int: ContinueWatchingItem?] = [:]
            for await (index, item) in group { found[index] = item }
            return entries.indices.compactMap { found[$0] ?? nil }
        }
    }

    private static func lookUp(
        entry: WatchProgressEntry,
        addonURLs: [String],
        client: AddonClient
    ) async -> ContinueWatchingItem? {
        for baseURL in addonURLs {
            guard let detail = try? await client.meta(
                baseURL: baseURL,
                type: entry.contentType,
                id: entry.contentID
            ) else { continue }

            let item = MetaItem(
                id: entry.contentID,
                type: entry.contentType,
                name: detail.name,
                poster: detail.poster,
                background: detail.background,
                logo: detail.logo,
                description: detail.description,
                releaseInfo: detail.releaseInfo
            )
            let episodeTitle = detail.videos.first {
                $0.season == entry.season && $0.episode == entry.episode
            }?.title?.trimmed.nilWhenEmpty

            return ContinueWatchingItem(
                item: item,
                addonBaseURL: baseURL,
                progress: entry,
                episodeTitle: episodeTitle
            )
        }
        return nil
    }
}

// MARK: - The shelf

/// One resume card.
///
/// Deliberately not the poster card the catalog rows use. A resume card answers
/// a different question — not "what is this" but "where was I" — so it is wide
/// rather than tall, it leads with the backdrop, and it carries the progress
/// bar that is the whole reason the shelf exists.
struct ContinueWatchingCard: View {
    let item: ContinueWatchingItem
    /// The card's artwork width. Height follows at sixteen by nine.
    let width: CGFloat
    var cornerRadius: CGFloat = 10
    let action: () -> Void

    @Environment(\.palette) private var palette

    private var height: CGFloat { (width * 9 / 16).rounded() }

    var body: some View {
        Button(action: action) {
            FocusReader { isFocused in
                VStack(alignment: .leading, spacing: 9) {
                    artwork
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(palette.accent.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                        }
                        .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)
                    caption
                }
                .contentShape(Rectangle())
                .scaleEffect(isFocused ? 1.06 : 1)
                .zIndex(isFocused ? 1 : 0)
                .animation(.spring(response: 0.34, dampingFraction: 0.74), value: isFocused)
            }
        }
        #if os(tvOS)
        // The TV has no press to respond to; it has focus, and a resume card
        // lifts on focus the way the poster cards beside it do.
        .buttonStyle(.plain)
        #else
        .buttonStyle(.pressable)
        #endif
        .accessibilityLabel(accessibilityLabel)
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(
                url: AddonClient.resolve(
                    item.item.background ?? item.item.poster,
                    relativeTo: item.addonBaseURL
                )
            ) {
                AnyView(fallback)
            }
            .frame(width: width, height: height)
            .clipped()

            // Artwork is unpredictable, so everything drawn over it gets its
            // own ground rather than trusting the picture to be dark enough.
            LinearGradient(
                colors: [.clear, .black.opacity(0.25), .black.opacity(0.82)],
                startPoint: .init(x: 0.5, y: 0.35),
                endPoint: .bottom
            )

            playGlyph

            VStack(alignment: .leading, spacing: 6) {
                if let remaining = item.remainingLabel {
                    Text(remaining)
                        .font(.system(size: max(9, (width * 0.062).rounded()), weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .background(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
                }

                ProgressBar(fraction: item.progress.fraction, tint: palette.accent)
                    .frame(height: 3)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 9)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // The same hairline the poster cards carry, so a shelf of wide cards
        // still reads as part of the same set.
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    /// Sits centred until the eye needs it elsewhere: it is the one element
    /// that says this card resumes rather than opens.
    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: (width * 0.11).rounded(), weight: .black))
            .foregroundStyle(.white)
            .padding((width * 0.055).rounded())
            .background(.black.opacity(0.42), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
            .frame(width: width, height: height)
    }

    /// An addon that ships no backdrop still has to produce a card that reads.
    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [.white.opacity(0.13), .white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: item.item.type.lowercased() == "series" ? "tv" : "film")
                .font(.system(size: (width * 0.14).rounded(), weight: .light))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.item.name)
                .font(.system(size: max(11, (width * 0.082).rounded()), weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let detail = captionDetail {
                Text(detail)
                    .font(.system(size: max(9, (width * 0.068).rounded()), weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The episode, and its title when the addon gave one — `S2 E7 · Chikara`
    /// tells a viewer far more about where they are than a number alone.
    private var captionDetail: String? {
        [item.episodeLabel, item.episodeTitle]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
            .nilWhenEmpty
    }

    private var accessibilityLabel: String {
        [item.item.name, item.episodeLabel, item.remainingLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// The bar itself: a thin rule, tinted with the account's accent so the shelf
/// belongs to whatever theme the viewer picked.
private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geometry.size.width * min(max(fraction, 0), 1)))
                    .shadow(color: tint.opacity(0.55), radius: 4)
            }
        }
    }
}
