import SwiftUI
import Combine

// MARK: - Settings

/// Where the optional TMDB key lives.
///
/// Trailers do not need it. They come from the addon's own meta response,
/// which already carries `trailerStreams`/`trailers` — so the home screen
/// plays trailers out of the box.
///
/// The key is a fallback for addons that don't carry trailers. Upstream
/// compiles its own in from `local.properties` (`BuildConfig.TMDB_API_KEY`),
/// which is a build secret this port doesn't have and mustn't ship, so a user
/// who wants that extra coverage supplies their own. Nothing else in the app
/// depends on it.
@MainActor
final class TmdbSettings: ObservableObject {
    static let shared = TmdbSettings()

    private static let keyKey = "nuvio.tmdb.apiKey"
    private static let trailersKey = "nuvio.tmdb.useTrailers"

    private let defaults: UserDefaults

    @Published var apiKey: String {
        didSet { defaults.set(apiKey.trimmed, forKey: Self.keyKey) }
    }

    /// Mirrors upstream's "Disable Trailers in TMDB Enrichment" toggle.
    @Published var useTrailers: Bool {
        didSet { defaults.set(useTrailers, forKey: Self.trailersKey) }
    }

    /// Trailers only ever autoplay muted, the way every streaming app opens.
    @Published var startMuted = true

    /// The addon path needs no credentials, so the toggle alone decides.
    var canFetchTrailers: Bool { useTrailers }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiKey = defaults.string(forKey: Self.keyKey) ?? ""
        self.useTrailers = defaults.object(forKey: Self.trailersKey) as? Bool ?? true
    }
}
