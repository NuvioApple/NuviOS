import SwiftUI
import Combine

// MARK: - Which addons answer

/// The user's addon list, kept where any screen can reach it.
///
/// `HomeViewModel` resolves the same list for its rows, but a detail page
/// pushed from search or the library has no view model to ask, and every
/// installed addon — not just the one a poster came from — gets a say in what
/// a title can be played from.
@MainActor
final class AddonScope: ObservableObject {
    @Published private(set) var baseURLs: [String] = AddonDirectory.defaultAddonURLs

    private var loadedProfileID: Int?

    /// Reloads only when the effective profile changed; profiles can share a
    /// list, so this compares `effectiveAddonProfileID` rather than the index.
    func refresh(session: AppSession, profile: Profile, force: Bool = false) async {
        guard force || loadedProfileID != profile.effectiveAddonProfileID else { return }
        loadedProfileID = profile.effectiveAddonProfileID

        guard case .signedIn(let userID, _) = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else {
            baseURLs = AddonDirectory.defaultAddonURLs
            return
        }

        do {
            baseURLs = try await AddonDirectory.addons(
                configuration: configuration,
                userID: userID,
                accessToken: token,
                profileID: profile.effectiveAddonProfileID
            )
        } catch {
            baseURLs = AddonDirectory.defaultAddonURLs
        }
    }
}

// MARK: - What is being played

/// Everything the player needs to open one thing: the address, and enough
/// naming for the transport bar and the now-playing card.
/// A source to fall back to, in the order the audition ranked them.
struct PlaybackAlternate: Equatable {
    let url: URL
    var headers: [String: String] = [:]
}

/// Enough to recognise one source again in a freshly fetched list.
///
/// Deliberately not the address: the address is the part that goes stale, and
/// a re-request exists precisely to replace it. What stays put across a
/// re-request is which addon answered and how the result described itself.
struct StreamFingerprint: Equatable, Sendable {
    var addonName: String
    var name: String?
    var title: String?
    var filename: String?

    init(_ stream: Stream) {
        addonName = stream.addonName
        name = stream.name
        title = stream.title
        filename = stream.behaviorHints.filename
    }

    /// The filename is the strongest signal — it names the actual release —
    /// but plenty of addons omit it, so the addon's own labelling stands in.
    func matches(_ stream: Stream) -> Bool {
        if let filename, let theirs = stream.behaviorHints.filename, !filename.isEmpty {
            return filename == theirs
        }
        return stream.addonName == addonName && stream.name == name && stream.title == title
    }
}

/// How to ask the addons for this title again.
///
/// Signed links are minted on request and die on their own schedule, so the
/// only real cure for an expired one is a new one. Carrying this into the
/// player is what lets it re-request without sending the viewer back to a list
/// to do by hand what the app can do for itself.
struct StreamRefresh: Equatable, Sendable {
    /// `movie` or `series`, as the addon protocol spells it.
    let type: String
    /// The meta id for a movie, the `series:season:episode` video id for an
    /// episode — the same id the picker asked with.
    let id: String
    let addonURLs: [String]
    /// The source that was playing, so the fresh list can be re-sorted to put
    /// the viewer's own choice back on top.
    let chosen: StreamFingerprint
    /// The debrid instructions for the source that was playing, when it had
    /// them. This is the direct line: rather than hoping the addon hands back
    /// a newer address than last time, the service is asked to mint one.
    var resolve: StreamClientResolve?
    var season: Int?
    var episode: Int?

    /// Mints a new address for the source that was playing, without going near
    /// an addon. Nil when this source isn't one the client can resolve.
    func reResolve() async -> PlaybackAlternate? {
        guard let resolve else { return nil }
        guard case .resolved(let url, _) = await DebridResolver.resolve(
            resolve,
            season: season,
            episode: episode
        ) else { return nil }
        return PlaybackAlternate(url: url)
    }

    /// Re-asks every addon and returns playable addresses, the viewer's source
    /// first when it is still on offer.
    func freshSources() async -> [PlaybackAlternate] {
        let streams = await StreamLoader.fetch(type: type, id: id, from: addonURLs)
        let playable = streams.filter(\.isPlayable)
        let mine = playable.filter { chosen.matches($0) }
        let rest = playable.filter { !chosen.matches($0) }
        return (mine + rest).compactMap { stream in
            guard let url = stream.playbackURL else { return nil }
            return PlaybackAlternate(url: url, headers: stream.behaviorHints.requestHeaders)
        }
    }
}

struct PlaybackRequest: Identifiable, Equatable {
    let url: URL
    let title: String
    let subtitle: String?
    /// Headers the source requires — `behaviorHints.proxyHeaders.request`.
    /// A link that needs a Referer answers 403 without them.
    var headers: [String: String] = [:]
    /// Identifies the title, not the stream, so a resume point survives
    /// picking a different source for the same episode next time.
    var resumeKey: String = ""
    /// The runners-up, best first. A source that fails — on opening or an hour
    /// in — is replaced from here without the viewer being sent back to a list,
    /// which is the difference between a title that keeps playing and one that
    /// stops on an error the viewer has to answer.
    var alternates: [PlaybackAlternate] = []
    /// How to ask for this title again. A queue of alternates only helps while
    /// one of them is still alive; when a list has sat long enough for the
    /// chosen link to expire, its neighbours are usually just as stale, and
    /// re-requesting is the only thing that produces a live address.
    var refresh: StreamRefresh?
    /// When this address was minted by a client-side resolve, if it was. An
    /// address seconds old cannot have expired, so the player skips its
    /// pre-open link check and saves the viewer that round trip.
    var mintedAt: Date?

    /// Identity is the *first* source only. Failing over swaps the address
    /// inside the player; if it changed this id, the full-screen cover would be
    /// torn down and rebuilt, which is exactly the interruption being avoided.
    var id: String { url.absoluteString }
}

#if os(macOS)

/// The window-level home of the Mac player.
///
/// On iOS and tvOS a stream opens in a full-screen cover, which the system
/// draws over everything. macOS has no such presentation, and a sheet is the
/// wrong shape for video: it sizes itself to its content, it hangs off the
/// window rather than filling it, and it cannot be taken full screen — which
/// is how the Mac player ended up a small letterboxed panel over the library.
///
/// So the Mac player is drawn at the root of the window instead, over the
/// sidebar and all, and this carries the request from the detail screen up to
/// there. Closing it clears the detail screen's own state too, so the two
/// never disagree about whether something is playing.
@MainActor
final class PlayerPresenter: ObservableObject {
    static let shared = PlayerPresenter()

    @Published private(set) var request: PlaybackRequest?

    private var dismissal: (() -> Void)?

    private init() {}

    func present(_ request: PlaybackRequest, onClose: @escaping () -> Void) {
        self.request = request
        dismissal = onClose
    }

    func close() {
        request = nil
        dismissal?()
        dismissal = nil
    }
}

#endif

extension View {
    /// Presents a stream: a full-screen cover on iOS and tvOS, the
    /// window-level Mac player above.
    @ViewBuilder
    func platformPlayerCover(item: Binding<PlaybackRequest?>) -> some View {
        #if os(macOS)
        onChange(of: item.wrappedValue) { _, new in
            guard let new else { return }
            PlayerPresenter.shared.present(new) { item.wrappedValue = nil }
        }
        #else
        fullScreenCover(item: item) { request in
            NuvioPlayerScreen(request: request)
        }
        #endif
    }
}

// MARK: - Finding streams

/// Fans a `stream` request out across every installed addon and collects what
/// comes back, in the user's addon order.
@MainActor
final class StreamLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded([Stream])
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var inFlight: Task<Void, Never>?

    /// `id` is the meta id for a movie and the `series:season:episode` video
    /// id for an episode.
    func load(type: String, id: String, from baseURLs: [String]) {
        inFlight?.cancel()
        state = .loading

        inFlight = Task { [weak self] in
            let ordered = await Self.fetch(type: type, id: id, from: baseURLs)

            guard !Task.isCancelled else { return }

            self?.state = ordered.isEmpty
                ? .failed("No streams for this title. Add a streaming addon and try again.")
                : .loaded(ordered)
        }
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        state = .idle
    }

    /// Asks every addon and returns what came back, deduplicated and in the
    /// user's own addon order.
    ///
    /// Split out of `load` because the player needs the same fan-out on its
    /// own account: when a link dies of old age, the way to get a live one is
    /// to ask the addons again, exactly as the picker first did.
    nonisolated static func fetch(type: String, id: String, from baseURLs: [String]) async -> [Stream] {
        let client = AddonClient()
        // Every addon is asked at once; the results are put back in the
        // user's own addon order so their preferred source leads.
        let answers: [Int: [Stream]] = await withTaskGroup(of: (Int, [Stream]).self) { group in
            for (index, baseURL) in baseURLs.enumerated() {
                group.addTask {
                    let streams = (try? await client.streams(baseURL: baseURL, type: type, id: id)) ?? []
                    guard !streams.isEmpty else { return (index, []) }
                    let name = (try? await client.manifest(baseURL: baseURL))?.name ?? ""
                    return (index, streams.map { var copy = $0; copy.addonName = name; return copy })
                }
            }
            var collected: [Int: [Stream]] = [:]
            for await (index, streams) in group { collected[index] = streams }
            return collected
        }

        var seen = Set<String>()
        return baseURLs.indices
            .flatMap { answers[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
            // Anything AVPlayer can open comes first; the rest stay
            // visible so a torrent-only answer isn't silently dropped.
            .sorted { $0.isPlayable && !$1.isPlayable }
    }
}

// MARK: - The player

// MARK: - Picking a stream

/// The sheet that stands between Play and the player: which episode, then
/// which source. A movie skips straight to the source list.
struct StreamPicker: View {
    let selection: MetaSelection
    let detail: MetaDetail?
    /// Preselected when the caller already knows the episode.
    var video: MetaVideo?

    @EnvironmentObject private var addons: AddonScope
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @StateObject private var loader = StreamLoader()
    @StateObject private var auto = StreamAutoSelector()
    @State private var playback: PlaybackRequest?
    /// One audition per episode: coming back from the player shouldn't launch
    /// the same stream again.
    @State private var auditioned = false
    @State private var chosenVideo: MetaVideo?
    @State private var chosenSeason: Int?
    @State private var externalError: String?
    /// True while a debrid service is being asked for a download link, which
    /// is a few seconds of network before the player can open.
    @State private var resolving = false

    private var item: MetaItem { selection.item }
    private var isSeries: Bool { !(detail?.seasons.isEmpty ?? true) }

    /// The episode whose streams are on screen, if any.
    private var activeVideo: MetaVideo? { video ?? chosenVideo }

    private var streamID: String? {
        if isSeries { return activeVideo?.id }
        return item.id
    }

    private var title: String { detail?.name ?? item.name }

    /// The episode, or the movie — deliberately not the stream, so switching
    /// source next time still resumes where the last one stopped.
    private var resumeKey: String {
        "\(item.type)|\(activeVideo?.id ?? item.id)"
    }

    private var subtitle: String? {
        guard let activeVideo else { return nil }
        return [activeVideo.code, activeVideo.title?.trimmed.nilWhenEmpty]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilWhenEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSeries, activeVideo == nil {
                    episodeList
                } else {
                    streamList
                }
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(isSeries && activeVideo == nil ? "Episodes" : "Play")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            #endif
        }
        .preferredColorScheme(.dark)
        .overlay {
            if resolving {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Getting the download link…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.6))
                .ignoresSafeArea()
            }
        }
        .task(id: streamID) {
            guard let streamID else { return }
            auto.cancel()
            auditioned = false
            loader.load(type: item.type, id: streamID, from: addons.baseURLs)
        }
        .onChange(of: loader.state) { _, state in
            // The audition can only start once the candidates are in.
            guard case .loaded(let streams) = state, !auditioned else { return }
            auditioned = true
            auto.start(streams: streams) { winner in
                // Anything the viewer does in the meantime cancels the job, so
                // reaching here means they left the choice to the app.
                play(winner)
            }
        }
        .onDisappear { auto.cancel() }
        .platformPlayerCover(item: $playback)
        .alert(
            "Couldn't open that stream",
            isPresented: Binding(
                get: { externalError != nil },
                set: { if !$0 { externalError = nil } }
            ),
            presenting: externalError
        ) { _ in
            Button("OK") { externalError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: Episodes

    private var episodeList: some View {
        let seasons = detail?.seasons ?? []
        let active = chosenSeason ?? seasons.first?.season
        let episodes = seasons.first { $0.season == active }?.episodes ?? []

        return VStack(spacing: 0) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(seasons, id: \.season) { season in
                            Button {
                                chosenSeason = season.season
                            } label: {
                                Text(season.season == 0 ? "Specials" : "Season \(season.season)")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .background {
                                Capsule().fill(
                                    season.season == active
                                        ? palette.accent.opacity(0.85)
                                        : Color.white.opacity(0.10)
                                )
                            }
                            .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }

            List(episodes) { episode in
                Button {
                    chosenVideo = episode
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text([episode.code, episode.title?.trimmed.nilWhenEmpty]
                            .compactMap { $0 }
                            .joined(separator: "  ·  "))
                            .font(.headline)
                            .foregroundStyle(.white)

                        if let overview = episode.overview?.trimmed.nilWhenEmpty {
                            Text(overview)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .hidingListBackground()
        }
    }

    // MARK: Sources

    @ViewBuilder
    private var streamList: some View {
        switch loader.state {
        case .idle, .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("Looking for streams…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.4))
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let streams):
            List {
                if auto.showsBanner {
                    Section { autoBanner }
                        .listRowBackground(Color.white.opacity(0.05))
                }

                if let subtitle {
                    Section {
                        Text(subtitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .listRowBackground(Color.clear)
                }

                ForEach(streams) { stream in
                    StreamRow(
                        stream: stream,
                        probe: auto.probe(for: stream),
                        isChoice: isAutoChoice(stream)
                    ) { play(stream) }
                        .listRowBackground(Color.white.opacity(0.05))
                }
            }
            .hidingListBackground()
        }
    }

    /// What the audition is doing, in one row at the top of the list.
    @ViewBuilder
    private var autoBanner: some View {
        switch auto.status {
        case .idle, .cancelled, .chose:
            EmptyView()
        case .reaching(let done, let total):
            autoBannerBody("Testing sources… \(done) of \(total)")
        case .measuring(let name):
            autoBannerBody("Measuring speed — \(name)")
        case .noneUsable:
            Label("None of these sources answered. Pick one to try anyway.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func autoBannerBody(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("The best one plays on its own.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            Button("Choose myself") { auto.cancel() }
                .font(.caption.weight(.semibold))
        }
    }

    private func isAutoChoice(_ stream: Stream) -> Bool {
        if case .chose(let winner) = auto.status { return winner.id == stream.id }
        return false
    }

    /// The fallback queue handed to the player, best first.
    ///
    /// The audition's ranking is used when it produced one, since those sources
    /// are known to answer. A source picked by hand before the audition
    /// finished falls back on the list's own order instead, which is still
    /// better than having nowhere to go.
    private func alternates(excluding chosen: Stream) -> [PlaybackAlternate] {
        var ordered = auto.ranking
        if ordered.isEmpty, case .loaded(let streams) = loader.state {
            ordered = streams.filter(\.isPlayable)
        }
        return ordered
            .filter { $0.id != chosen.id }
            .compactMap { stream in
                guard let url = stream.playbackURL else { return nil }
                return PlaybackAlternate(url: url, headers: stream.behaviorHints.requestHeaders)
            }
    }

    /// The addon gave instructions instead of an address, so the download is
    /// asked for now — at the moment of playing, which is the only moment that
    /// produces a link with its full life ahead of it.
    private func resolveThenPlay(_ stream: Stream) {
        guard let resolve = stream.clientResolve else { return }
        resolving = true
        Task {
            let result = await DebridResolver.resolve(
                resolve,
                season: activeVideo?.season ?? resolve.season,
                episode: activeVideo?.episode ?? resolve.episode
            )
            resolving = false
            switch result {
            case .resolved(let url, _):
                playback = request(for: stream, url: url, headers: [:], mintedAt: Date())
            case .missingKey:
                externalError = "\(resolve.debridService?.displayName ?? "That service") isn't set up on this account."
            case .notCached:
                externalError = "\(resolve.debridService?.displayName ?? "That service") doesn't have this ready to stream. Try a different source."
            case .unavailable, .failed:
                externalError = "Couldn't get a download link for that source. Try a different one."
            }
        }
    }

    private func request(
        for stream: Stream,
        url: URL,
        headers: [String: String],
        mintedAt: Date? = nil
    ) -> PlaybackRequest {
        PlaybackRequest(
            url: url,
            title: title,
            subtitle: subtitle,
            headers: headers,
            resumeKey: resumeKey,
            alternates: alternates(excluding: stream),
            refresh: streamID.map { id in
                StreamRefresh(
                    type: item.type,
                    id: id,
                    addonURLs: addons.baseURLs,
                    chosen: StreamFingerprint(stream),
                    resolve: stream.clientResolve,
                    season: activeVideo?.season,
                    episode: activeVideo?.episode
                )
            },
            mintedAt: mintedAt
        )
    }

    private func play(_ stream: Stream) {
        // A deliberate tap ends the audition, whatever it was about to decide.
        auto.cancel()

        if stream.needsResolve {
            resolveThenPlay(stream)
            return
        }

        if let url = stream.playbackURL {
            playback = request(for: stream, url: url, headers: stream.behaviorHints.requestHeaders)
            return
        }

        // Torrents need a torrent client and YouTube needs its own player;
        // anything carrying a web address is handed to the system rather than
        // failing silently.
        if let external = stream.openableURL {
            #if os(iOS)
            UIApplication.shared.open(external)
            #else
            externalError = "This source opens in a browser, which the TV app can't do."
            #endif
            return
        }
        externalError = stream.infoHash == nil
            ? "This source didn't give a playable address."
            : "This is a torrent source, which this build can't play."
    }
}

/// One row in the source list. A result that can't be played is dimmed rather
/// than hidden, so a torrent-only title explains itself.
private struct StreamRow: View {
    let stream: Stream
    /// What dialling this source found, once it has been dialled.
    var probe: StreamProbe?
    var isChoice: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.title2)
                    .foregroundStyle(glyphTint)

                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.headline)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(stream.isPlayable ? 1 : 0.6))
                        .lineLimit(2)

                    if let detail = stream.detailLine {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if isChoice {
                            Text("BEST")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.green.opacity(0.25)))
                                .foregroundStyle(.green)
                        }

                        // A row that has no address yet says which service
                        // will be asked for one, so a viewer can see why it
                        // takes a moment longer to open than its neighbours.
                        if stream.needsResolve,
                           let service = stream.clientResolve?.debridService {
                            Text(service.displayName)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.blue.opacity(0.22)))
                                .foregroundStyle(.blue)
                        }

                        if !stream.addonName.isEmpty {
                            Text(stream.addonName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.4))
                        }

                        // Naming the container on the row saves opening a
                        // stream only to be told the system can't read it.
                        if let container = stream.container {
                            Text(container)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.4))
                        }

                        // What the test found, so a dead 4K link says so on
                        // the row instead of after being opened.
                        if let summary = probe?.summary {
                            Text(summary)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(probe?.isReachable == true ? .green.opacity(0.75) : .orange.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var glyph: String {
        guard stream.isPlayable else { return "link.circle" }
        switch probe?.verdict {
        case .reachable: return "checkmark.circle.fill"
        case .unreachable: return "xmark.circle"
        default: return "play.circle.fill"
        }
    }

    private var glyphTint: Color {
        guard stream.isPlayable else { return .white.opacity(0.4) }
        switch probe?.verdict {
        case .reachable: return .green.opacity(0.85)
        case .unreachable: return .orange.opacity(0.7)
        default: return .white.opacity(0.9)
        }
    }
}


private extension View {
    /// tvOS lists have no material background to hide, and the modifier that
    /// hides one isn't available there.
    @ViewBuilder
    func hidingListBackground() -> some View {
        #if os(tvOS)
        self
        #else
        scrollContentBackground(.hidden)
        #endif
    }
}
