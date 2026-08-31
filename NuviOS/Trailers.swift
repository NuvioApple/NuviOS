#if os(iOS)
import SwiftUI
import Combine
import WebKit

// MARK: - Lookup

/// Finds a title's YouTube trailer.
///
/// The addon is asked first. Cinemeta — and everything modelled on it —
/// already returns `trailerStreams`/`trailers` alongside the artwork and
/// description, so the trailer costs one request the app would make anyway
/// and needs no credentials of any kind.
///
/// TMDB is the fallback, and only when the user has supplied their own key.
/// Upstream compiles a key into the build (`BuildConfig.TMDB_API_KEY`); this
/// port can't ship someone else's, and now that the source is public it
/// certainly can't. So TMDB covers the addons that don't carry trailers, and
/// everyone else gets trailers without setting anything up.
///
/// Upstream de-muxes the YouTube stream so ExoPlayer can play it. This port
/// plays the id in YouTube's own embedded player instead — no extraction, and
/// it stays inside YouTube's terms.
actor TrailerService {
    static let shared = TrailerService()

    private static let base = "https://api.themoviedb.org/3"

    /// `nil` means "looked, found nothing" — worth remembering so a hero that
    /// has no trailer isn't queried again every time it comes round.
    private var cache: [String: String?] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// `addonBaseURL` is the addon that served this item, so the meta request
    /// goes back to the one that already knows about it.
    func youTubeKey(for item: MetaItem, addonBaseURL: String?, apiKey: String) async -> String? {
        let cacheKey = "\(item.type)|\(item.id)"
        if let cached = cache[cacheKey] { return cached }

        var resolved = await addonTrailerID(for: item, baseURL: addonBaseURL)

        let key = apiKey.trimmed
        if resolved == nil, !key.isEmpty {
            resolved = await lookUp(item: item, apiKey: key)
        }

        cache[cacheKey] = resolved
        return resolved
    }

    /// The addon's own answer. A failure here is not worth surfacing: the
    /// caller either falls through to TMDB or shows the backdrop it was
    /// already showing.
    private func addonTrailerID(for item: MetaItem, baseURL: String?) async -> String? {
        guard let baseURL,
              !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let detail = try? await AddonClient().meta(
            baseURL: baseURL,
            type: item.type,
            id: item.id
        )
        return detail?.trailerYouTubeIDs.first
    }

    private func lookUp(item: MetaItem, apiKey: String) async -> String? {
        guard let tmdbID = await tmdbID(for: item, apiKey: apiKey) else { return nil }
        let mediaType = Self.mediaType(for: item.type)
        return await videoKey(tmdbID: tmdbID, mediaType: mediaType, apiKey: apiKey)
    }

    /// Addons identify titles by IMDb id far more often than by TMDB id, so
    /// the usual path is TMDB's `/find` with `external_source=imdb_id`.
    private func tmdbID(for item: MetaItem, apiKey: String) async -> Int? {
        let id = item.id.trimmed

        // Some addons hand back `tmdb:1234` or a bare numeric id.
        if id.lowercased().hasPrefix("tmdb:"), let value = Int(id.dropFirst(5)) { return value }
        if !id.hasPrefix("tt"), let value = Int(id) { return value }

        // Series ids arrive as `tt123:1:4` when a specific episode is meant.
        let imdbID = id.split(separator: ":").first.map(String.init) ?? id
        guard imdbID.hasPrefix("tt") else { return nil }

        struct FindResponse: Decodable {
            struct Hit: Decodable { let id: Int }
            let movieResults: [Hit]
            let tvResults: [Hit]

            enum CodingKeys: String, CodingKey {
                case movieResults = "movie_results"
                case tvResults = "tv_results"
            }
        }

        guard let response: FindResponse = await get(
            "/find/\(imdbID)",
            query: ["external_source": "imdb_id"],
            apiKey: apiKey
        ) else { return nil }

        return Self.mediaType(for: item.type) == "tv"
            ? (response.tvResults.first?.id ?? response.movieResults.first?.id)
            : (response.movieResults.first?.id ?? response.tvResults.first?.id)
    }

    private func videoKey(tmdbID: Int, mediaType: String, apiKey: String) async -> String? {
        struct VideosResponse: Decodable {
            struct Video: Decodable {
                let key: String
                let site: String
                let type: String
                let official: Bool?
                let language: String?

                enum CodingKeys: String, CodingKey {
                    case key, site, type, official
                    case language = "iso_639_1"
                }
            }
            let results: [Video]
        }

        // No `language` filter: asking for one drops every trailer a title
        // only published in another, and the ranking below prefers English
        // anyway.
        guard let response: VideosResponse = await get(
            "/\(mediaType)/\(tmdbID)/videos",
            query: [:],
            apiKey: apiKey
        ) else { return nil }

        let youTube = response.results.filter {
            $0.site.caseInsensitiveCompare("YouTube") == .orderedSame && !$0.key.isEmpty
        }

        // Upstream's ranking: an official trailer first, then any trailer,
        // then a teaser — English preferred at every step.
        func score(_ video: VideosResponse.Video) -> Int {
            var value = 0
            if video.type.caseInsensitiveCompare("Trailer") == .orderedSame { value += 8 }
            else if video.type.caseInsensitiveCompare("Teaser") == .orderedSame { value += 4 }
            if video.official == true { value += 3 }
            if video.language?.lowercased() == "en" { value += 2 }
            return value
        }

        return youTube
            .filter { score($0) > 0 }
            .max { score($0) < score($1) }?
            .key
    }

    private static func mediaType(for type: String) -> String {
        switch type.lowercased() {
        case "series", "tv", "show": "tv"
        default: "movie"
        }
    }

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String],
        apiKey: String
    ) async -> T? {
        var components = URLComponents(string: Self.base + path)
        components?.queryItems = ([("api_key", apiKey)] + query.map { ($0.key, $0.value) })
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Player

/// YouTube's own embedded player, muted and chromeless, sized to fill.
///
/// The embed is used rather than an extracted stream deliberately: it is the
/// supported way to play a YouTube video in a third-party app, and it keeps
/// this port clear of stream extraction.
///
/// The player itself is Google's `YTPlayerView` — the helper the official
/// guide points at — vendored under `YouTubePlayerHelper/`. It is the same
/// WKWebView-over-the-IFrame-API shape this file used to hand-roll, but the
/// bridge, the origin handling and the state parsing are Google's rather than
/// ours.
struct YouTubeTrailerView: UIViewRepresentable {
    let videoID: String
    var isMuted: Bool
    /// Fires once the embed has actually started, so the backdrop can cross
    /// fade into it instead of blinking to black.
    var onReady: () -> Void
    var onEnded: () -> Void

    /// Chromeless and autoplaying: the billboard owns the controls, and a
    /// trailer that needs a tap isn't a backdrop.
    private static let playerVars: [String: Any] = [
        "autoplay": 1,
        "mute": 1,
        "controls": 0,
        "playsinline": 1,
        "rel": 0,
        "modestbranding": 1,
        "iv_load_policy": 3,
        "fs": 0,
        "disablekb": 1,
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> YTPlayerView {
        let player = YTPlayerView()
        player.delegate = context.coordinator
        player.backgroundColor = .black
        player.isUserInteractionEnabled = false
        context.coordinator.load(videoID, into: player, playerVars: Self.playerVars)
        return player
    }

    func updateUIView(_ player: YTPlayerView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onEnded = onEnded
        context.coordinator.load(videoID, into: player, playerVars: Self.playerVars)
        context.coordinator.apply(isMuted: isMuted, to: player)
    }

    static func dismantleUIView(_ player: YTPlayerView, coordinator: Coordinator) {
        // Without this the embed keeps playing audio after the view is gone.
        player.stopVideo()
        player.removeWebView()
    }

    final class Coordinator: NSObject, YTPlayerViewDelegate {
        var onReady: () -> Void
        var onEnded: () -> Void

        /// What's actually loaded, so a re-render of the same page doesn't
        /// reload the video out from under a playing trailer.
        private var loadedVideoID: String?
        private var hasStarted = false
        private var lastMuted = true

        init(onReady: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onReady = onReady
            self.onEnded = onEnded
        }

        func load(_ videoID: String, into player: YTPlayerView, playerVars: [String: Any]) {
            guard loadedVideoID != videoID else { return }
            loadedVideoID = videoID
            hasStarted = false
            lastMuted = true
            player.load(withVideoId: videoID, playerVars: playerVars)
        }

        /// The helper has no mute API of its own, but it exposes its web view,
        /// and the page it loads keeps the player in a global.
        func apply(isMuted: Bool, to player: YTPlayerView) {
            guard hasStarted, isMuted != lastMuted else { return }
            lastMuted = isMuted
            player.webView?.evaluateJavaScript(
                isMuted ? "player.mute();" : "player.unMute(); player.setVolume(100);"
            )
        }

        // MARK: YTPlayerViewDelegate

        func playerViewDidBecomeReady(_ playerView: YTPlayerView) {
            playerView.playVideo()
        }

        func playerView(_ playerView: YTPlayerView, didChangeTo state: YTPlayerState) {
            switch state {
            case .playing:
                guard !hasStarted else { return }
                hasStarted = true
                onReady()
            case .ended:
                onEnded()
            default:
                break
            }
        }

        /// An unplayable video — age-gated, region-blocked, embed-disabled —
        /// is treated as no trailer at all, so the artwork stays put.
        func playerView(_ playerView: YTPlayerView, receivedError error: YTPlayerError) {
            onEnded()
        }

        /// Black, not white: anything else flashes behind the embed while the
        /// iframe API loads.
        func playerViewPreferredWebViewBackgroundColor(_ playerView: YTPlayerView) -> UIColor {
            .black
        }
    }
}
#endif
