import SwiftUI
import Combine

// MARK: - Settings

/// Where the TMDB key lives.
///
/// Upstream compiles its own key in from `local.properties`
/// (`BuildConfig.TMDB_API_KEY`), which is a build secret this port doesn't
/// have and mustn't ship. So the key is the user's own: trailers stay off
/// until one is entered, and nothing else in the app depends on it.
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

    var canFetchTrailers: Bool { useTrailers && !apiKey.trimmed.isEmpty }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiKey = defaults.string(forKey: Self.keyKey) ?? ""
        self.useTrailers = defaults.object(forKey: Self.trailersKey) as? Bool ?? true
    }
}
