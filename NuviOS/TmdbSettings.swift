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
    private static let hoverKey = "nuvio.tmdb.hoverPreviews"
    private static let trailerioKey = "nuvio.trailerio.url"
    private static let focusPreviewsKey = "nuvio.trailerio.focusPreviews"
    private static let trailerSoundKey = "nuvio.trailerio.sound"

    private let defaults: UserDefaults

    @Published var apiKey: String {
        didSet { defaults.set(apiKey.trimmed, forKey: Self.keyKey) }
    }

    /// Mirrors upstream's "Disable Trailers in TMDB Enrichment" toggle.
    @Published var useTrailers: Bool {
        didSet { defaults.set(useTrailers, forKey: Self.trailersKey) }
    }

    /// Whether a hovered card on the Mac plays a muted clip once it opens.
    /// Off until asked for: it streams video for every card the pointer rests on.
    @Published var hoverPreviews: Bool {
        didSet { defaults.set(hoverPreviews, forKey: Self.hoverKey) }
    }

    /// The address of a Trailerio-style addon (see `TrailerioClient`). Its
    /// trailers are plain video files, so they are the only kind a TV can play.
    @Published var trailerioURL: String {
        didSet { defaults.set(trailerioURL.trimmed, forKey: Self.trailerioKey) }
    }

    /// Whether focusing a poster on the TV starts its trailer, muted, in the
    /// card. Off for anyone who finds a moving shelf distracting.
    @Published var focusPreviews: Bool {
        didSet { defaults.set(focusPreviews, forKey: Self.focusPreviewsKey) }
    }

    /// Whether the hero's trailer plays with its sound. The remote's
    /// Play/Pause button flips it while a trailer is on screen.
    @Published var trailerSound: Bool {
        didSet { defaults.set(trailerSound, forKey: Self.trailerSoundKey) }
    }

    @Published var preferIMAX: Bool {
        didSet { defaults.set(preferIMAX, forKey: TrailerioPreferences.preferIMAXKey) }
    }

    /// The trailer addons to ask, in order. Empty if the viewer cleared it.
    var trailerBases: [String] {
        let url = trailerioURL.trimmed
        return url.isEmpty ? [] : [url]
    }

    static let defaultTrailerioURL = "https://trailerio.cc"

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
        self.hoverPreviews = defaults.object(forKey: Self.hoverKey) as? Bool ?? false
        self.trailerioURL = defaults.string(forKey: Self.trailerioKey) ?? Self.defaultTrailerioURL
        self.focusPreviews = defaults.object(forKey: Self.focusPreviewsKey) as? Bool ?? true
        self.trailerSound = defaults.object(forKey: Self.trailerSoundKey) as? Bool ?? true
        self.preferIMAX = defaults.object(forKey: TrailerioPreferences.preferIMAXKey) as? Bool ?? true
    }
}
