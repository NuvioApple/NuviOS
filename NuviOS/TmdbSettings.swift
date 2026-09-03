import SwiftUI
import Combine

// MARK: - Settings

/// Where the optional TMDB key lives.
///
/// Trailers do not need it. They come from the addon's own meta response,
/// which already carries `trailerStreams`/`trailers` — so the home screen
/// plays trailers out of the box.
///
/// The key is a fallback for addons that don't carry trailers, and now also
/// sharpens cast photos on the detail page (see Cast.swift). Upstream
/// compiles its own in from `local.properties` (`BuildConfig.TMDB_API_KEY`);
/// this port can't ship one to every user the way upstream does, since the
/// source is public. Whoever builds it, though, can do the same thing for
/// their own copy: `Secrets.swift` (see `Secrets.example.swift`) is
/// git-ignored and never reaches the public repo, so a personal key baked in
/// there works without typing it into Settings on every install. Nothing
/// else in the app depends on it either way — `effectiveAPIKey` is what
/// callers actually use, and it falls back to the Settings field when
/// there's no compiled-in key.
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

    /// What TMDB calls should actually use: whatever the viewer typed into
    /// Settings if they typed anything, otherwise whoever built this copy's
    /// own compiled-in key (empty in the public repo — see Secrets.swift).
    var effectiveAPIKey: String {
        let typed = apiKey.trimmed
        return typed.isEmpty ? Secrets.tmdbAPIKey : typed
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiKey = defaults.string(forKey: Self.keyKey) ?? ""
        self.useTrailers = defaults.object(forKey: Self.trailersKey) as? Bool ?? true
    }
}
